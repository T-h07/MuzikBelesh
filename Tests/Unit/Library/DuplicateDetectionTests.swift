import XCTest
import GRDB
@testable import OFFLINE

final class DuplicateDetectionTests: XCTestCase {
    private func source(_ f: LibraryFixture, name: String, seed: Int) throws -> URL {
        let url = try f.sources().appendingPathComponent(name); try LibraryFixture.wav(seed: seed).write(to: url); return url
    }
    func testExactHashAndDifferentFilenameReuseOneTrackAndOnePhysicalCopy() async throws {
        let f = try LibraryFixture(count: 0); let firstURL = try source(f, name: "First.wav", seed: 1)
        let first = try await f.storage.importAudio(from: firstURL)
        let secondURL = try f.sources().appendingPathComponent("Renamed.wav"); try Data(contentsOf: firstURL).write(to: secondURL)
        let second = try await f.storage.importAudio(from: secondURL)
        XCTAssertFalse(first.duplicate); XCTAssertTrue(second.duplicate); XCTAssertEqual(second.track.id, first.track.id)
        XCTAssertEqual(try f.storage.tracks.all().count, 1); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.paths.music.path).count, 1)
    }
    func testSameTitleWithDifferentBytesIsNotAHashDuplicate() async throws {
        let f = try LibraryFixture(count: 0); let one = try source(f, name: "Same.wav", seed: 1)
        _ = try await f.storage.importAudio(from: one)
        try LibraryFixture.wav(seed: 2).write(to: one)
        let second = try await f.storage.importAudio(from: one)
        XCTAssertFalse(second.duplicate); XCTAssertEqual(try f.storage.tracks.all().count, 2)
        XCTAssertEqual(Set(try f.storage.tracks.all().map(\.title)), ["Same"])
    }
    func testSourceIdentityReusesTrackEvenWhenEncodingBytesDiffer() async throws {
        let f = try LibraryFixture(count: 0); let one = try source(f, name: "A.wav", seed: 1); let two = try source(f, name: "B.wav", seed: 2)
        let a = try await f.storage.importAudio(from: one, sourceType: "youtube", sourceIdentifier: "source-A")
        let b = try await f.storage.importAudio(from: two, sourceType: "youtube", sourceIdentifier: "source-A")
        XCTAssertTrue(b.duplicate); XCTAssertEqual(a.track.id, b.track.id)
        XCTAssertEqual(try Data(contentsOf: f.paths.musicURL(relativePath: a.track.fileRelativePath)), try Data(contentsOf: one))
        XCTAssertEqual(try f.storage.tracks.all().count, 1)
    }
    func testDifferentSourceIDsAndTypesRemainDistinctForDifferentBytes() async throws {
        let f = try LibraryFixture(count: 0)
        let a = try await f.storage.importAudio(from: source(f, name: "A.wav", seed: 1), sourceType: "youtube", sourceIdentifier: "same")
        let b = try await f.storage.importAudio(from: source(f, name: "B.wav", seed: 2), sourceType: "files", sourceIdentifier: "same")
        let c = try await f.storage.importAudio(from: source(f, name: "C.wav", seed: 3), sourceType: "youtube", sourceIdentifier: "different")
        XCTAssertEqual(Set([a.track.id, b.track.id, c.track.id]).count, 3)
    }
    func testDuplicateAfterRestartPreservesEditedMetadataAndRecordsSourceAlias() async throws {
        let f = try LibraryFixture(count: 0); let url = try source(f, name: "A.wav", seed: 1)
        let a = try await f.storage.importAudio(from: url)
        try f.repository.editMetadata(trackID: a.track.id, draft: TrackMetadataDraft(title: "User Title", artist: "User Artist", album: "User Album"))
        let reopened = try StorageCoordinator(paths: f.paths)
        let b = try await reopened.importAudio(from: url, sourceType: "youtube", sourceIdentifier: "alias")
        XCTAssertTrue(b.duplicate); XCTAssertEqual(b.track.id, a.track.id); XCTAssertEqual(b.track.title, "User Title")
        let alias = try await reopened.database.dbQueue.read { try LibraryRepository.sourceTrack(type: "youtube", identifier: "alias", db: $0)?.id }
        XCTAssertEqual(alias, a.track.id)
    }
    func testConcurrentImportsReturnOnePersistentWinnerWithoutOrphanCopies() async throws {
        let f = try LibraryFixture(count: 0); let url = try source(f, name: "A.wav", seed: 1)
        let outcomes = try await withThrowingTaskGroup(of: ImportResult.self) { group in
            for _ in 0..<6 { group.addTask { try await f.storage.importAudio(from: url, sourceType: "youtube", sourceIdentifier: "concurrent") } }
            var values: [ImportResult] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(Set(outcomes.map { $0.track.id }).count, 1)
        XCTAssertEqual(outcomes.filter { !$0.duplicate }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.paths.music.path).count, 1)
        let sources = try await f.storage.database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_sources") }
        XCTAssertEqual(sources, 1)
    }
    func testConcurrentSeparateCoordinatorsStillUseDatabaseDuplicateCheck() async throws {
        let f = try LibraryFixture(count: 0); let second = try StorageCoordinator(paths: f.paths); let url = try source(f, name: "A.wav", seed: 1)
        async let a = f.storage.importAudio(from: url)
        async let b = second.importAudio(from: url)
        let values = try await [a, b]
        XCTAssertEqual(values[0].track.id, values[1].track.id)
        XCTAssertEqual(try f.storage.tracks.all().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.paths.music.path).count, 1)
    }
    func testExactDuplicateRepairsMissingManagedFileWithoutLosingEdits() async throws {
        let f = try LibraryFixture(count: 0); let url = try source(f, name: "A.wav", seed: 1)
        let a = try await f.storage.importAudio(from: url)
        try f.repository.editMetadata(trackID: a.track.id, draft: TrackMetadataDraft(title: "Edited", artist: "", album: ""))
        try FileManager.default.removeItem(at: f.paths.musicURL(relativePath: a.track.fileRelativePath)); try f.storage.reconcileMissingFiles()
        let b = try await f.storage.importAudio(from: url)
        XCTAssertTrue(b.duplicate); XCTAssertEqual(b.track.id, a.track.id); XCTAssertEqual(b.track.title, "Edited"); XCTAssertEqual(b.track.availability, .available)
        XCTAssertEqual(try f.storage.audio.sha256(url: f.paths.musicURL(relativePath: a.track.fileRelativePath)), a.track.contentSHA256)
    }
    func testChangedExternalFileIsNotOverwrittenByDuplicateImport() async throws {
        let f = try LibraryFixture(count: 0); let url = try source(f, name: "A.wav", seed: 1)
        let a = try await f.storage.importAudio(from: url); let changed = LibraryFixture.wav(seed: 9)
        let managed = try f.paths.musicURL(relativePath: a.track.fileRelativePath); try changed.write(to: managed)
        let b = try await f.storage.importAudio(from: url)
        XCTAssertTrue(b.duplicate); XCTAssertEqual(b.track.availability, .modified); XCTAssertEqual(try Data(contentsOf: managed), changed)
    }
    func testImportAfterFailedAttemptLeavesNoBrokenDuplicateIdentity() async throws {
        let f = try LibraryFixture(count: 0); let url = try f.sources().appendingPathComponent("A.wav"); try Data([1, 2]).write(to: url)
        do { _ = try await f.storage.importAudio(from: url, sourceType: "youtube", sourceIdentifier: "retry"); XCTFail("Invalid audio must fail") } catch { }
        try LibraryFixture.wav(seed: 1).write(to: url)
        let result = try await f.storage.importAudio(from: url, sourceType: "youtube", sourceIdentifier: "retry")
        XCTAssertFalse(result.duplicate); XCTAssertEqual(try f.storage.tracks.all().count, 1); XCTAssertEqual(try f.foreignKeys(), 0)
    }
}
