import Foundation
import UIKit

/// Credits listening time only while audio is actually progressing.
///
/// The player reports observations (`observe(position:duration:playing:)`) from its periodic
/// time observer and transport changes. Time is credited between two consecutive observations
/// only when the earlier one was taken while playing and the playback position moved forward,
/// and never more than the monotonic time that elapsed (plus a small jitter tolerance). Paused,
/// buffering, seeking and skipped time therefore never count, and a seek can never inflate the
/// total. Background, lock-screen and AirPods playback are counted because the observer keeps
/// running while audio plays.
///
/// A session row is written only once audio has been credited, so selecting a song that never
/// plays creates nothing. Every write is guarded: analytics failures are recorded in
/// `lastError` and never thrown into playback.
@MainActor final class ListeningSessionTracker {
    private struct Session {
        let id: String
        let trackID: String
        let context: ListeningContext
        var durationMs: Int64?
        var persisted = false
        /// When credited audio first began; the session's start time and start day.
        var startedAt: Date?
        /// Credited milliseconds per local day (fractional), and what has been written.
        var credited: [String: Double] = [:]
        var written: [String: Int64] = [:]
        var writtenTotal: Int64 { written.values.reduce(0, +) }
        var creditedTotal: Int64 { credited.values.reduce(0) { $0 + Int64($1.rounded(.down)) } }
    }

    private struct Baseline { let position: Double; let uptime: TimeInterval }

    private let store: ListeningSessionStore?
    /// Monotonic clock; injectable for tests.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Wall clock used for day keys and timestamps; injectable for tests.
    var now: () -> Date = { Date() }
    var calendar: Calendar = .current
    /// Extra credit allowed per interval above elapsed monotonic time, for callback jitter.
    let jitterTolerance: TimeInterval = 0.25

    private var session: Session?
    private var baseline: Baseline?
    private var terminationObserver: NSObjectProtocol?
    private(set) var lastError: String?
    private(set) var recoveredSessions = 0

    init(store: ListeningSessionStore?) {
        self.store = store
        do { recoveredSessions = try store?.recoverInterrupted() ?? 0 }
        catch { lastError = "Interrupted listening sessions could not be recovered." }
        terminationObserver = NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(reason: "terminated", natural: false) }
        }
    }

    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    var activeTrackID: String? { session?.trackID }
    var activeContext: ListeningContext? { session?.context }
    /// Whole milliseconds credited to the current session so far.
    var currentListenedMs: Int64 { session?.creditedTotal ?? 0 }

    /// A new item was loaded. A continuation (same song reloaded after a failure or media
    /// reset) keeps the session; anything else finalizes the previous session as replaced.
    func prepare(trackID: String, durationSeconds: Double?, context: ListeningContext, continuing: Bool = false) {
        baseline = nil
        if continuing, session?.trackID == trackID { return }
        finish(reason: "replaced", natural: false)
        session = Session(id: UUID().uuidString, trackID: trackID, context: context, durationMs: Self.milliseconds(durationSeconds))
    }

    func observe(position: Double, duration: Double?, playing: Bool) {
        guard session != nil, position.isFinite else { baseline = nil; return }
        if let ms = Self.milliseconds(duration) { session?.durationMs = ms }
        let current = uptime()
        if let baseline {
            let progressed = position - baseline.position
            let elapsed = current - baseline.uptime
            if progressed > 0, elapsed > 0 { credit(seconds: min(progressed, elapsed + jitterTolerance), elapsed: elapsed) }
        }
        baseline = playing ? Baseline(position: position, uptime: current) : nil
    }

    /// A seek or other position jump: the next observation starts a fresh interval.
    func discontinuity() { baseline = nil }

    /// Playback stopped progressing (pause, interruption, failure): write what was credited.
    func pause() { baseline = nil; flush() }

    /// Leaving the foreground: persist so a later termination loses nothing already heard.
    func checkpoint() { flush() }

    /// Ends the current session. `natural` is true only for an accepted end-of-item event.
    func finish(reason: String, natural: Bool) {
        baseline = nil
        guard var current = session else { return }
        session = nil
        guard current.persisted || current.creditedTotal > 0 else { return }
        let listened = current.creditedTotal
        _ = write(&current, endReason: reason, completed: ListeningPolicy.isCompleted(listenedMs: listened, durationMs: current.durationMs, natural: natural))
    }

    // MARK: Private

    private func credit(seconds: Double, elapsed: Double) {
        guard var current = session, seconds > 0 else { return }
        let end = now()
        let start = end.addingTimeInterval(-max(seconds, elapsed))
        if current.startedAt == nil { current.startedAt = end.addingTimeInterval(-seconds) }
        for (day, ms) in ListeningDayKey(calendar: calendar).split(start: start, end: end, milliseconds: seconds * 1000) {
            current.credited[day, default: 0] += ms
        }
        session = current
        if current.creditedTotal - current.writtenTotal >= ListeningPolicy.checkpointMs { flush() }
    }

    private func flush() {
        guard var current = session, current.creditedTotal > current.writtenTotal else { return }
        if write(&current, endReason: nil, completed: false) { session = current }
    }

    /// Returns true when the store accepted the write. On failure nothing is marked written,
    /// so the same deltas are retried by the next flush (each write is one transaction).
    private func write(_ current: inout Session, endReason: String?, completed: Bool) -> Bool {
        guard let store else { return false }
        let at = now()
        do {
            if !current.persisted {
                let startedAt = current.startedAt ?? at
                try store.begin(ListeningSessionStart(id: current.id, trackID: current.trackID, startedAt: startedAt, startDay: ListeningDayKey(calendar: calendar).key(for: startedAt), durationMs: current.durationMs, context: current.context))
                current.persisted = true
            }
            var deltas: [String: Int64] = [:]
            var written = current.written
            for (day, value) in current.credited {
                let whole = Int64(value.rounded(.down))
                let delta = whole - (written[day] ?? 0)
                if delta > 0 { deltas[day] = delta; written[day] = whole }
            }
            let total = written.values.reduce(0, +)
            try store.write(ListeningSessionUpdate(id: current.id, listenedMs: total, durationMs: current.durationMs,
                                                   qualified: ListeningPolicy.isQualified(listenedMs: total, durationMs: current.durationMs),
                                                   completed: completed, dayDeltas: deltas, at: at, endReason: endReason))
            current.written = written
            lastError = nil
            return true
        } catch {
            lastError = "Listening activity could not be saved."
            return false
        }
    }

    private static func milliseconds(_ seconds: Double?) -> Int64? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Int64((seconds * 1000).rounded())
    }
}
