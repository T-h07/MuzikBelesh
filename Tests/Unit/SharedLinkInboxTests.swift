import XCTest
@testable import OFFLINE

final class SharedLinkInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: SharedLinkInbox { SharedLinkInbox(directory: root) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRestartDuplicateReconciliationAndOldAcceptedLink() throws {
        let id = "dQw4w9WgXcQ"
        try inbox.save(id, now: .distantPast)
        let original = try XCTUnwrap(inbox.first())
        try inbox.save("9bZkp7q19f0")
        try inbox.save(id)
        XCTAssertEqual(try inbox.first(), original)
        XCTAssertEqual(YouTubeURLValidator.videoID(from: original.url), id)
        try inbox.acknowledge(original.id)
        try inbox.acknowledge(original.id)
        let next = try XCTUnwrap(inbox.first())
        XCTAssertEqual(next.videoID, "9bZkp7q19f0")
        try inbox.acknowledge(next.id)
        XCTAssertNil(try inbox.first())
    }

    func testConcurrentWritesAndCapacityPreserveEveryAcceptedLink() async throws {
        let store = inbox
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<SharedLinkInbox.capacity {
                group.addTask {
                    _ = try store.first()
                    try store.save(String(format: "fixture%04d", i))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertThrowsError(try store.save("dQw4w9WgXcQ"))
        var seen = Set<String>()
        while let item = try store.first() {
            XCTAssertTrue(seen.insert(item.videoID).inserted)
            try store.acknowledge(item.id)
        }
        XCTAssertEqual(seen.count, SharedLinkInbox.capacity)
    }

    func testUnreadableUnknownAndInvalidRecordsArePreserved() throws {
        try inbox.save("dQw4w9WgXcQ")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: file)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        envelope["version"] = 2
        let future = try JSONSerialization.data(withJSONObject: envelope)
        let invalid = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "dQw4w9WgXcQ", with: "../outside").utf8)
        for bytes in [Data("{".utf8), future, invalid, Data(repeating: 65, count: 9000)] {
            try bytes.write(to: file, options: .atomic)
            XCTAssertThrowsError(try inbox.first())
            XCTAssertThrowsError(try inbox.save("9bZkp7q19f0"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    /// A phone that ran a canceled Phase 10.8 test IPA holds a version 2 queue. YouTube
    /// shares survive with their identity and order; Spotify shares are dropped; the original
    /// is copied aside; the file returns to version 1 and sharing keeps working.
    func testCanceledPhase108VersionTwoQueueIsRestoredOnce() throws {
        let file = root.appendingPathComponent("PendingYouTubeLinks-v1.json")
        let a = UUID(), spotify = UUID(), b = UUID()
        // Exactly the format the Phase 10.8 build encoded.
        let v2 = """
            {"version":2,"pending":[{"id":"\(a.uuidString)","kind":"youtubeVideo","value":"dQw4w9WgXcQ","created":100},\
            {"id":"\(spotify.uuidString)","kind":"spotifyPlaylist","value":"37i9dQZF1DXcBWIGoYBM5M","created":150},\
            {"id":"\(b.uuidString)","kind":"youtubeVideo","value":"9bZkp7q19f0","created":200.5}]}
            """
        try Data(v2.utf8).write(to: file)
        let first = try XCTUnwrap(inbox.first())
        XCTAssertEqual(first, PendingShare(id: a, videoID: "dQw4w9WgXcQ", created: Date(timeIntervalSinceReferenceDate: 100)))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(stored["version"] as? Int, 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(SharedLinkInbox.canceledVersion2BackupPrefix) }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backups[0])), Data(v2.utf8), "Original bytes are kept")

        try inbox.acknowledge(a)
        XCTAssertEqual(try inbox.first(), PendingShare(id: b, videoID: "9bZkp7q19f0", created: Date(timeIntervalSinceReferenceDate: 200.5)))
        try inbox.acknowledge(b)
        XCTAssertNil(try inbox.first(), "The Spotify share is not delivered")
        try inbox.save("dQw4w9WgXcQ")
        XCTAssertEqual(try inbox.first()?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(SharedLinkInbox.canceledVersion2BackupPrefix) }.count, 1,
                       "Restored once")

        // An emptied 10.8 queue (every share acknowledged) is also accepted.
        try Data(#"{"version":2,"pending":[]}"#.utf8).write(to: file, options: .atomic)
        XCTAssertNil(try inbox.first())
        try inbox.save("9bZkp7q19f0")
        XCTAssertEqual(try inbox.first()?.videoID, "9bZkp7q19f0")
    }

    func testUnknownVersionTwoContentStaysRejectedAndUntouched() throws {
        let file = root.appendingPathComponent("PendingYouTubeLinks-v1.json")
        for bytes in [#"{"version":2,"pending":[{"id":"\#(UUID().uuidString)","kind":"appleMusic","value":"x","created":1}]}"#,
                      #"{"version":2,"pending":[{"id":"\#(UUID().uuidString)","kind":"youtubeVideo","value":"../outside","created":1}]}"#,
                      #"{"version":3,"pending":[]}"#].map({ Data($0.utf8) }) {
            try bytes.write(to: file, options: .atomic)
            XCTAssertThrowsError(try inbox.first())
            XCTAssertThrowsError(try inbox.save("9bZkp7q19f0"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(SharedLinkInbox.canceledVersion2BackupPrefix) })
    }

    func testUnavailableOrUnwritableStorageAndInvalidID() throws {
        XCTAssertThrowsError(try SharedLinkInbox(directory: nil).save("9bZkp7q19f0"))
        let path = root.appendingPathComponent("file")
        try Data().write(to: path)
        XCTAssertThrowsError(try SharedLinkInbox(directory: path).save("9bZkp7q19f0"))
        XCTAssertThrowsError(try inbox.save("../../bad"))
        XCTAssertNil(try inbox.first())
    }
}
