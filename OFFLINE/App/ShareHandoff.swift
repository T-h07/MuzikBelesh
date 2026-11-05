import UIKit

// Serialization keeps an acknowledgement ordered with the next inbox read.
actor ShareHandoff {
    private lazy var inbox: SharedLinkInbox = {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing"),
           let raw = process.environment["MB_UI_TEST_ID"], let id = UUID(uuidString: raw) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareTests-" + id.uuidString)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = SharedLinkInbox(directory: root)
            if process.arguments.contains("--pending-share") { try? fixture.save("9bZkp7q19f0") }
            return fixture
        }
        #endif
        return .installed()
    }()
    private var delivered: UUID?

    func next() throws -> PendingShare? {
        if let delivered { try acknowledge(delivered) }
        return try inbox.first()
    }

    func acknowledge(_ id: UUID) throws {
        delivered = id
        try inbox.acknowledge(id)
        delivered = nil
    }
}
