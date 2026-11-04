import Foundation

@MainActor enum AppBootstrap {
    static func container() -> AppContainer {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing") {
            guard let identifier = process.environment["MB_UI_TEST_ID"], UUID(uuidString: identifier) != nil else { fatalError("UI tests require an isolated library identifier") }
            do {
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MuzikBeleshUITests", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
                let root = parent.appendingPathComponent(identifier, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
                guard root.path.hasPrefix(parent.path + "/") else { fatalError("Invalid UI test root") }
                if process.arguments.contains("--reset-ui-library"), FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                let storage = try StorageCoordinator(paths: AppStoragePaths(root: root))
                if process.arguments.contains("--reset-ui-library") { try seed(storage) }
                return AppContainer(storage: storage)
            } catch { fatalError("Could not create the isolated UI test library") }
        }
        #endif
        return AppContainer()
    }
    #if DEBUG
    private static func seed(_ storage: StorageCoordinator) throws {
        for (index, title) in ["Fixture A", "Fixture B", "Fixture C"].enumerated() {
            let id = "ui-track-\(["a", "b", "c"][index])"
            let url = try storage.paths.musicURL(relativePath: "\(id).wav")
            var data = Data()
            func le<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
            // UI navigation tests need sustained real playback. Two-second clips
            // repeatedly hit EOF and rebuild history/search while XCTest snapshots.
            // Short endpoint fixtures remain in the playback unit/integration tests.
            let samples = 180 * 8000 + index * 400
            data.append(contentsOf: "RIFF".utf8); le(UInt32(36 + samples * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
            le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(8000)); le(UInt32(16000)); le(UInt16(2)); le(UInt16(16))
            data.append(contentsOf: "data".utf8); le(UInt32(samples * 2)); data.append(Data(repeating: UInt8(index), count: samples * 2)); try data.write(to: url)
            let now = Date(timeIntervalSince1970: 1_600_000_000 + Double(index))
            try storage.tracks.save(StoredTrack(id: id, title: title, artistID: nil, albumID: nil, durationMs: Int64(180000 + index * 50), fileRelativePath: url.lastPathComponent, fileExtension: "wav", fileSizeBytes: Int64(data.count), contentSHA256: storage.audio.sha256(url: url), artworkRelativePath: nil, availability: .available, dateAdded: now, dateModified: now, originalFilename: url.lastPathComponent, metadataSource: "ui-test"))
            try LibraryRepository(db: storage.database.dbQueue).editMetadata(trackID: id, draft: TrackMetadataDraft(title: title, artist: "Fixture Artist", album: "Fixture Album"))
        }
        storage.reload()
    }
    #endif
}
