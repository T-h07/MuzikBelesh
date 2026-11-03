import Foundation

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
    private var explicitQueue: [String] = []
    private let makeShuffle: ([String]) -> [String]

    init(makeShuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) { self.makeShuffle = makeShuffle }

    func restore(context: [String], currentID: String?, shuffleEnabled: Bool, repeatMode: RepeatMode, shuffleOrder: [String], shufflePosition: Int, history: [String], historyPosition: Int, explicitQueue: [String]) {
        self.context = context; self.currentID = currentID; self.shuffleEnabled = shuffleEnabled; self.repeatMode = repeatMode
        self.shuffleOrder = shuffleOrder; self.shufflePosition = max(0, shufflePosition)
        self.history = history; self.historyPosition = history.isEmpty ? -1 : min(max(-1, historyPosition), history.count - 1)
        self.explicitQueue = explicitQueue
    }

    func setContext(_ ids: [String], currentID: String?) {
        let filtered = ids.filter { !context.isEmpty ? ids.contains($0) : true }
        var unique: [String] = []
        for id in filtered where !unique.contains(id) { unique.append(id) }
        context = unique
        self.currentID = currentID
        if shuffleEnabled && !shuffleOrder.isEmpty && Set(shuffleOrder) == Set(context.filter { $0 != currentID }) { return }
        if shuffleEnabled { rebuildShuffle(excluding: currentID) }
    }

    func setCurrent(_ id: String?) { currentID = id }
    func setExplicitQueue(_ ids: [String]) { explicitQueue = ids }
    func setShuffleEnabled(_ enabled: Bool) { shuffleEnabled = enabled; if enabled { rebuildShuffle(excluding: currentID) } else { shuffleOrder = []; shufflePosition = 0 } }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % RepeatMode.allCases.count] }

    func next() -> String? {
        if !explicitQueue.isEmpty { return explicitQueue.removeFirst() }
        guard !context.isEmpty else { return nil }
        if repeatMode == .one, let currentID { return currentID }
        if shuffleEnabled {
            if shufflePosition >= shuffleOrder.count {
                guard repeatMode == .all else { return nil }
                rebuildShuffle(excluding: currentID)
            }
            guard shufflePosition < shuffleOrder.count else { return nil }
            let result = shuffleOrder[shufflePosition]; shufflePosition += 1; return result
        }
        guard let currentID, let index = context.firstIndex(of: currentID) else { return context.first }
        if index + 1 < context.count { return context[index + 1] }
        return repeatMode == .all ? context.first : nil
    }

    func previous() -> String? {
        if historyPosition > 0 { return history[historyPosition - 1] }
        guard let currentID, let index = context.firstIndex(of: currentID), index > 0 else { return nil }
        return context[index - 1]
    }

    func didStart(_ id: String, direction: NavigationDirection) {
        currentID = id
        if direction == .previous, historyPosition > 0 { historyPosition -= 1; return }
        if historyPosition + 1 < history.count, history[historyPosition + 1] == id { historyPosition += 1; return }
        history = Array(history.prefix(max(0, historyPosition + 1))); history.append(id); historyPosition = history.count - 1
    }

    func hasNext() -> Bool { !explicitQueue.isEmpty || repeatMode == .one && currentID != nil || context.count > 1 && repeatMode == .all || (currentID == nil && !context.isEmpty) || (currentID.flatMap { context.firstIndex(of: $0) }.map { $0 + 1 < context.count } ?? false) }
    func hasPrevious() -> Bool { previous() != nil || historyPosition > 0 }

    private func rebuildShuffle(excluding id: String?) { shuffleOrder = makeShuffle(context.filter { $0 != id }); shufflePosition = 0 }
}
