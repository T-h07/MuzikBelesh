import Foundation

struct PendingShare: Codable, Equatable, Identifiable {
    let id: UUID
    let videoID: String
    let created: Date
    var url: String { "https://www.youtube.com/watch?v=\(videoID)" }
}

struct SharedLinkInbox {
    enum Failure: Error { case unavailable, invalid, full }
    private struct Queue: Codable {
        var version = 1
        var pending: [PendingShare] = []
    }
    static let group = "group.com.th07.muzikbelesh.inbox"
    static let capacity = 16
    private let directory: URL?

    init(directory: URL?) { self.directory = directory }

    static func installed() -> Self {
        let bundle = Bundle.main
        let app = bundle.bundleURL.pathExtension == "appex"
            ? Bundle(url: bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) : bundle
        let prefix = "com.th07.muzikbelesh."
        var candidates = (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? [])
        if let id = app?.bundleIdentifier, id.hasPrefix(prefix) {
            candidates.append(group + "." + String(id.dropFirst(prefix.count)))
        }
        let allowed = candidates.filter { value in
            guard value.hasPrefix(group + ".") else { return false }
            let suffix = value.dropFirst(group.count + 1)
            return suffix.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
        }
        for id in allowed + [group] {
            if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return Self(directory: directory)
            }
        }
        return Self(directory: nil)
    }

    func first() throws -> PendingShare? { try transaction { $0.first } }

    func save(_ videoID: String, now: Date = Date()) throws {
        guard YouTubeURLValidator.isValidID(videoID) else { throw Failure.invalid }
        try transaction { records in
            guard !records.contains(where: { $0.videoID == videoID }) else { return }
            guard records.count < Self.capacity else { throw Failure.full }
            records.append(PendingShare(id: UUID(), videoID: videoID, created: now))
        }
    }

    func acknowledge(_ id: UUID) throws {
        try transaction { $0.removeAll { $0.id == id } }
    }

    // Coordinate the entire read/modify/atomic-replace operation between processes.
    // A missing file is a new inbox. Other read errors must never erase earlier shares.
    private func transaction<T>(_ change: @escaping (inout [PendingShare]) throws -> T) throws -> T {
        guard let directory else { throw Failure.unavailable }
        let file = directory.appendingPathComponent("PendingYouTubeLinks-v1.json")
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
            outcome = Result {
                var queue = Queue()
                do {
                    let props = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard props.isRegularFile == true, props.isSymbolicLink != true,
                          let size = props.fileSize, size <= 8192 else { throw Failure.invalid }
                    let data = try Data(contentsOf: url)
                    queue = try JSONDecoder().decode(Queue.self, from: data)
                    guard queue.version == 1, queue.pending.count <= Self.capacity,
                          Set(queue.pending.map(\.id)).count == queue.pending.count,
                          queue.pending.allSatisfy({ YouTubeURLValidator.isValidID($0.videoID) }) else { throw Failure.invalid }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    // First use.
                }
                let previous = queue.pending
                let result = try change(&queue.pending)
                if queue.pending != previous {
                    try JSONEncoder().encode(queue).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                return result
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw Failure.unavailable }
        return try outcome.get()
    }
}
