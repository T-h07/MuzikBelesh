import Foundation
import GRDB

/// Loads listening summaries off the main thread. Views never run analytics SQL while
/// rendering: they read the last published summary, which stays visible while a refresh runs
/// so values transition instead of flashing.
@MainActor
final class ListeningStatsService: ObservableObject {
    typealias Reader = @Sendable (ListeningRange) throws -> ListeningSummary

    @Published private(set) var summaries: [ListeningRange: ListeningSummary] = [:]
    @Published private(set) var loading: Set<ListeningRange> = []
    @Published private(set) var failures: [ListeningRange: String] = [:]

    private let reader: Reader?
    /// Persists the in-progress session before a read so the numbers include it.
    var beforeLoad: (() -> Void)?
    private var tasks: [ListeningRange: Task<Void, Never>] = [:]

    init(reader: Reader?) { self.reader = reader }

    convenience init(database: DatabaseQueue?) {
        guard let database else { self.init(reader: nil); return }
        self.init(reader: { range in try ListeningAnalyticsRepository(db: database).summary(range: range) })
    }

    func summary(_ range: ListeningRange) -> ListeningSummary? { summaries[range] }
    func isLoading(_ range: ListeningRange) -> Bool { loading.contains(range) }
    func failure(_ range: ListeningRange) -> String? { failures[range] }

    func load(_ range: ListeningRange) {
        guard let reader else { failures[range] = "Listening activity isn't available because local storage couldn't be opened."; return }
        beforeLoad?()
        tasks[range]?.cancel()
        loading.insert(range)
        tasks[range] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try reader(range) } }.value
            guard let self, !Task.isCancelled else { return }
            self.loading.remove(range)
            self.tasks[range] = nil
            switch result {
            case .success(let summary): self.summaries[range] = summary; self.failures[range] = nil
            case .failure: self.failures[range] = "Your listening activity couldn't be loaded."
            }
        }
    }

    /// Reloads every range that has been shown, for example after returning to the dashboard.
    func refreshLoaded() { for range in Set(summaries.keys).union(failures.keys) { load(range) } }
}

#if DEBUG
/// Deterministic listening history for UI tests and simulator captures (`--listening-fixture`).
/// Written through the same repository API the tracker uses.
enum ListeningFixtureSeeder {
    static func seed(storage: StorageCoordinator, now: Date = Date(), calendar: Calendar = .current) throws {
        let repository = ListeningAnalyticsRepository(db: storage.database.dbQueue)
        let library = LibraryRepository(db: storage.database.dbQueue)
        let playlist = try library.createPlaylist(name: "Fixture Mix", description: "")
        try library.addTracks(["ui-track-a", "ui-track-b", "ui-track-c"], playlistID: playlist.id)
        let keys = ListeningDayKey(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        // (days ago, track, minutes, context)
        let plan: [(Int, String, Int, ListeningContext)] = [
            (0, "ui-track-a", 34, ListeningContext(kind: "playlist", sourceID: playlist.id)),
            (0, "ui-track-b", 12, .unknown),
            (1, "ui-track-a", 48, ListeningContext(kind: "playlist", sourceID: playlist.id)),
            (2, "ui-track-c", 21, ListeningContext(kind: "library", sourceID: nil)),
            (3, "ui-track-b", 66, ListeningContext(kind: "playlist", sourceID: playlist.id)),
            (5, "ui-track-a", 27, ListeningContext(kind: "library", sourceID: nil)),
            (6, "ui-track-c", 9, .manualQueue),
            (12, "ui-track-b", 40, ListeningContext(kind: "library", sourceID: nil)),
            (20, "ui-track-a", 55, ListeningContext(kind: "playlist", sourceID: playlist.id)),
            (45, "ui-track-c", 80, ListeningContext(kind: "library", sourceID: nil)),
            (90, "ui-track-a", 120, ListeningContext(kind: "library", sourceID: nil))
        ]
        for (daysAgo, trackID, minutes, context) in plan {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                  let start = calendar.date(byAdding: .hour, value: 9, to: day) else { continue }
            // Split long listening into three-minute plays, like real sessions.
            var remaining = minutes * 60_000
            var offset: TimeInterval = 0
            while remaining > 0 {
                let ms = min(remaining, 180_000)
                let at = start.addingTimeInterval(offset)
                let id = UUID().uuidString
                try repository.begin(ListeningSessionStart(id: id, trackID: trackID, startedAt: at, startDay: keys.key(for: at), durationMs: 180_000, context: context))
                try repository.write(ListeningSessionUpdate(id: id, listenedMs: Int64(ms), durationMs: 180_000,
                                                            qualified: ListeningPolicy.isQualified(listenedMs: Int64(ms), durationMs: 180_000),
                                                            completed: ms >= 150_000, dayDeltas: [keys.key(for: at): Int64(ms)],
                                                            at: at.addingTimeInterval(Double(ms) / 1000), endReason: "completed"))
                remaining -= ms
                offset += Double(ms) / 1000 + 5
            }
        }
    }
}
#endif
