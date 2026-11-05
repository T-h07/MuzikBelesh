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

    func testUnavailableOrUnwritableStorageAndInvalidID() throws {
        XCTAssertThrowsError(try SharedLinkInbox(directory: nil).save("9bZkp7q19f0"))
        let path = root.appendingPathComponent("file")
        try Data().write(to: path)
        XCTAssertThrowsError(try SharedLinkInbox(directory: path).save("9bZkp7q19f0"))
        XCTAssertThrowsError(try inbox.save("../../bad"))
        XCTAssertNil(try inbox.first())
    }
}
