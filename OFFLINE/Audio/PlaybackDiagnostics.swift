import Foundation

enum PlaybackCommandSource { @TaskLocal static var value = "app" }

/// Session-only allowlisted fields. Never accepts titles, URLs, paths or raw errors.
@MainActor final class PlaybackDiagnostics: ObservableObject {
    struct Event: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let operationID: UUID?
        let action: String
        let fields: [String: String]
    }
    @Published private(set) var events: [Event] = []
    let capacity: Int
    private var aliases: [String: String] = [:]
    init(capacity: Int = 300) { self.capacity = max(1, capacity) }
    func trackAlias(_ id: String?) -> String {
        guard let id else { return "none" }
        if let alias = aliases[id] { return alias }
        // Bound identifiers too; these are session-local pseudonyms, not library IDs.
        if aliases.count >= capacity { aliases.removeAll() }
        let alias = UUID().uuidString
        aliases[id] = alias
        return alias
    }
    func record(_ action: String, operationID: UUID?, fields: [String: String]) {
        events.append(Event(id: UUID(), timestamp: Date(), operationID: operationID, action: action, fields: fields))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }
    func clear() { events.removeAll(); aliases.removeAll() }
    func export(currentState: [String: String]) -> String {
        struct Trace: Encodable { let currentState: [String: String]; let events: [Event] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(Trace(currentState: currentState, events: events)), encoding: .utf8)) ?? "{}"
    }
}
