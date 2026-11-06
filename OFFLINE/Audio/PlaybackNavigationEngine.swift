import Foundation

enum PlaybackAdvanceReason { case automatic, manual }

/// Platform-independent source of truth for playback navigation.
/// AVPlayer, SwiftUI and MediaPlayer only ask this engine for the next transition.
final class PlaybackNavigationEngine {
    private(set) var context: [String] = []
    private(set) var currentID: String?
    private(set) var shuffleEnabled = false
    private(set) var repeatMode: RepeatMode = .all
    private(set) var shuffleOrder: [String] = []
    private(set) var shufflePosition = 0
    private(set) var history: [String] = []
    private(set) var historyPosition = -1
    static let historyLimit = 1000
    private var explicitQueue: [String] = []
    private let makeShuffle: ([String]) -> [String]

    init(makeShuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) { self.makeShuffle = makeShuffle }

    func restore(context: [String], currentID: String?, shuffleEnabled: Bool, repeatMode: RepeatMode, shuffleOrder: [String], shufflePosition: Int, history: [String], historyPosition: Int, explicitQueue: [String]) {
        self.context = context; self.currentID = currentID; self.shuffleEnabled = shuffleEnabled; self.repeatMode = repeatMode
        self.shuffleOrder = shuffleOrder; self.shufflePosition = min(shuffleOrder.count, max(0, shufflePosition))
        self.history = history; self.historyPosition = history.isEmpty ? -1 : min(max(-1, historyPosition), history.count - 1)
        self.explicitQueue = explicitQueue
        trimHistory()
        reconcileHistoryCursor()
    }

    func setContext(_ ids: [String], currentID: String?) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let oldContext = Set(context)
        context = unique
        self.currentID = currentID
        let available = Set(context)
        let before = history.prefix(max(0, historyPosition + 1)).filter { available.contains($0) }
        let after = history.dropFirst(max(0, historyPosition + 1)).filter { available.contains($0) }
        history = before + after; historyPosition = before.count - 1
        guard shuffleEnabled else { return }
        if shuffleOrder.isEmpty && shufflePosition == 0 { rebuildShuffle(excluding: currentID); return }
        let consumed = Array(shuffleOrder.prefix(shufflePosition)).filter { available.contains($0) }
        let remaining = Array(shuffleOrder.dropFirst(shufflePosition)).filter { available.contains($0) }
        shuffleOrder = consumed + remaining + context.filter { $0 != currentID && !oldContext.contains($0) }
        shufflePosition = consumed.count
    }

    func setCurrent(_ id: String?) { currentID = id }
    func setExplicitQueue(_ ids: [String]) { explicitQueue = ids }
    func setShuffleEnabled(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        reconcileHistoryCursor()
        shuffleEnabled = enabled
        if enabled { rebuildShuffle(excluding: currentID) }
        else { shuffleOrder = []; shufflePosition = 0 }
    }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % RepeatMode.allCases.count] }

    func next(reason: PlaybackAdvanceReason = .automatic) -> String? {
        if !explicitQueue.isEmpty { return explicitQueue.removeFirst() }
        guard !context.isEmpty else { return nil }
        if shuffleEnabled, hasCurrentHistoryEntry, historyPosition + 1 < history.count { return history[historyPosition + 1] }
        if repeatMode == .one, let currentID { return currentID }
        if shuffleEnabled {
            if shufflePosition >= shuffleOrder.count {
                guard repeatMode == .all || reason == .manual else { return nil }
                rebuildShuffle(excluding: currentID)
                if shuffleOrder.isEmpty, reason == .manual { shuffleOrder = context }
            }
            guard shufflePosition < shuffleOrder.count else { return nil }
            let result = shuffleOrder[shufflePosition]; shufflePosition += 1; return result
        }
        guard let currentID, let index = context.firstIndex(of: currentID) else { return context.first }
        if index + 1 < context.count { return context[index + 1] }
        return repeatMode == .all ? context.first : nil
    }

    func previous() -> String? {
        if shuffleEnabled {
            return hasCurrentHistoryEntry && historyPosition > 0 ? history[historyPosition - 1] : nil
        }
        guard let currentID, let index = context.firstIndex(of: currentID) else { return nil }
        if index > 0 { return context[index - 1] }
        return repeatMode == .all ? context.last : nil
    }

    func didStart(_ id: String, direction: NavigationDirection) {
        currentID = id
        // Only move the history cursor when the committed song matches that slot.
        // A sequential predecessor need not be the previous history entry.
        if direction == .previous, historyPosition > 0, history[historyPosition - 1] == id { historyPosition -= 1; return }
        if direction == .forward, historyPosition >= 0, historyPosition + 1 < history.count, history[historyPosition + 1] == id { historyPosition += 1; return }
        history = Array(history.prefix(max(0, historyPosition + 1))); history.append(id); historyPosition = history.count - 1
        trimHistory()
    }

    func hasNext(reason: PlaybackAdvanceReason = .automatic, explicitQueue: [String]? = nil) -> Bool {
        if !(explicitQueue ?? self.explicitQueue).isEmpty { return true }
        guard !context.isEmpty else { return false }
        if shuffleEnabled, hasCurrentHistoryEntry, historyPosition + 1 < history.count { return true }
        if repeatMode == .one { return currentID != nil }
        if shuffleEnabled {
            return shufflePosition < shuffleOrder.count || repeatMode == .all || reason == .manual
        }
        guard let currentID, let index = context.firstIndex(of: currentID) else { return true }
        return index + 1 < context.count || repeatMode == .all
    }
    func hasPrevious() -> Bool { previous() != nil }

    private func trimHistory() {
        guard history.count > Self.historyLimit else { return }
        let start = max(0, min(history.count - Self.historyLimit, historyPosition - Self.historyLimit / 2))
        history = Array(history[start..<(start + Self.historyLimit)])
        historyPosition -= start
    }

    private var hasCurrentHistoryEntry: Bool {
        history.indices.contains(historyPosition) && history[historyPosition] == currentID
    }

    private func reconcileHistoryCursor() {
        guard !hasCurrentHistoryEntry else { return }
        // Keep the history; repair only its cursor against the committed song.
        historyPosition = currentID.flatMap { history.lastIndex(of: $0) } ?? -1
    }

    func copy() -> PlaybackNavigationEngine {
        let result = PlaybackNavigationEngine(makeShuffle: makeShuffle)
        result.restore(context: context, currentID: currentID, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode, shuffleOrder: shuffleOrder, shufflePosition: shufflePosition, history: history, historyPosition: historyPosition, explicitQueue: explicitQueue)
        return result
    }

    private func rebuildShuffle(excluding id: String?) {
        shuffleOrder = makeShuffle(context.filter { $0 != id })
        if shuffleOrder.isEmpty, context.count == 1, repeatMode == .all { shuffleOrder = context }
        shufflePosition = 0
    }
}
