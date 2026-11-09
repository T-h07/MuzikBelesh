import Foundation
import XCTest
import ZIPFoundation
@testable import OFFLINE

final class PlaylistImportZIPTests: XCTestCase {
    private typealias F = PlaylistImportFixtures

    func testMixedArchiveHasIndependentCandidatesAndMemberIdentities() throws {
        let archive = try F.zip([
            ("A.csv", F.csv(500)), ("folder/B.csv", F.csv(200)),
            ("Playlist1.json", F.json([F.playlist(3)])), ("Playlist2.json", F.json([F.playlist(0)])),
            ("Bad.csv", Data("Track Name\n\"unclosed".utf8)), ("Readme.txt", Data("Synthetic notes".utf8))
        ])
        let report = try F.parse(archive, filename: "Account.zip")
        XCTAssertEqual(report.validCount, 4); XCTAssertEqual(report.candidates.count, 5)
        XCTAssertEqual(report.candidates.compactMap(\.source).map { $0.entries.count }, [500, 200, 3, 0])
        XCTAssertEqual(Set(report.candidates.compactMap(\.operationID)).count, 4)
        XCTAssertTrue(report.candidates[4].diagnostics[0].contains("Bad.csv"))
        XCTAssertEqual(report.notes.count, 1)
    }

    func testDuplicateContentInSeparateMembersRetainsSeparateIdentities() throws {
        let report = try F.parse(F.zip([("one/Same.csv", F.csv(2)), ("two/Same.csv", F.csv(2))]), filename: "Batch.zip")
        XCTAssertEqual(report.validCount, 2)
        XCTAssertNotEqual(report.candidates[0].operationID, report.candidates[1].operationID)
        XCTAssertEqual(report.candidates[0].source?.name, report.candidates[1].source?.name)
    }

    func testUnsafeMemberPathsAndSymlinksAreRejected() throws {
        for path in ["../escape.csv", "/absolute.csv", "a/../../escape.csv", "C:/drive.csv", "a\\file.csv", "a//file.csv", "./file.csv", "a /file.csv", "a\u{0000}.csv"] {
            XCTAssertThrowsError(try F.parse(F.zip([(path, F.csv(1))]), filename: "Unsafe.zip"))
        }
        XCTAssertThrowsError(try F.parse(F.zip([("link.csv", Data("../outside".utf8))], type: .symlink), filename: "Unsafe.zip"))
    }

    func testDuplicateCanonicalNamesAndFileDirectoryConflictsAreRejected() throws {
        for names in [["a.csv", "a.csv"], ["A.csv", "a.csv"], ["é.csv", "e\u{301}.csv"], ["folder", "folder/a.csv"]] {
            XCTAssertThrowsError(try F.parse(F.zip(names.map { ($0, F.csv(1)) }), filename: "Conflict.zip"))
        }
    }

    func testNestedArchiveByExtensionOrMagicIsRejected() throws {
        let nested = try F.zip([("one.csv", F.csv(1))])
        for name in ["nested.zip", "disguised.csv"] {
            XCTAssertThrowsError(try F.parse(F.zip([(name, nested)]), filename: "Nested.zip"))
        }
    }

    func testUnreadableTruncatedAndTrailingDataArchivesFailWholly() throws {
        let archive = try F.zip([("A.csv", F.csv(1))])
        for bytes in [Data(), Data("not a ZIP".utf8), Data(archive.dropLast()), archive + Data([1])] {
            XCTAssertThrowsError(try F.parse(bytes, filename: "Corrupt.zip"))
        }
    }

    func testClassicDataDescriptorsWithAndWithoutSignature() throws {
        for signed in [false, true] {
            var bytes = try F.zip([("A.csv", F.csv(2))], compression: .none)
            let central = try F.signature(bytes, [0x50, 0x4b, 0x01, 0x02])
            let end = try F.signature(bytes, [0x50, 0x4b, 0x05, 0x06])
            func value(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
            }
            let crc = value(central + 16), compressed = value(central + 20), expanded = value(central + 24)
            let prefix = signed ? 4 : 0
            var descriptor = Data(count: prefix + 12)
            if signed { F.put(0x08074b50, in: &descriptor, at: 0) }
            F.put(crc, in: &descriptor, at: prefix)
            F.put(compressed, in: &descriptor, at: prefix + 4)
            F.put(expanded, in: &descriptor, at: prefix + 8)
            // Preserve ZIPFoundation's UTF-8 flag while enabling the descriptor bit.
            bytes[6] |= 8; bytes[central + 8] |= 8
            for offset in [14, 18, 22] { F.put(0, in: &bytes, at: offset) }
            bytes.insert(contentsOf: descriptor, at: central)
            F.put(UInt32(central + descriptor.count), in: &bytes, at: end + descriptor.count + 16)
            let report = try F.parse(bytes, filename: "Descriptor.zip")
            XCTAssertEqual(report.validCount, 1); XCTAssertEqual(report.candidates[0].source?.entries.count, 2)
        }
    }

    func testDirectoryEntriesAndUTF8Names() throws {
        let archive = try Archive(data: Data(), accessMode: .create)
        try archive.addEntry(with: "Music/", type: .directory, uncompressedSize: 0) { _, _ in Data() }
        let content = F.csv(1)
        try archive.addEntry(with: "Music/Été.csv", type: .file, uncompressedSize: Int64(content.count)) { position, count in
            content.subdata(in: Int(position)..<(Int(position) + count))
        }
        let report = try F.parse(XCTUnwrap(archive.data), filename: "Unicode.zip")
        XCTAssertEqual(report.validCount, 1); XCTAssertEqual(report.candidates[0].name, "Été")
    }

    func testEncryptionCompressionAndLocalCentralDisagreementAreRejected() throws {
        let original = try F.zip([("A.csv", F.csv(1))], compression: .none)
        let central = try F.signature(original, [0x50, 0x4b, 0x01, 0x02])
        for (offset, value, length) in [(central + 8, UInt32(1), 2), (central + 10, 99, 2), (6, 1, 2), (18, 1, 4), (central + 42, 5, 4), (central + 6, 45, 2)] {
            var data = original; F.put(value, in: &data, at: offset, length: length)
            XCTAssertThrowsError(try F.parse(data, filename: "Header.zip"))
        }
        var changedName = original; changedName[30] = UInt8(ascii: "B")
        XCTAssertThrowsError(try F.parse(changedName, filename: "Names.zip"))
    }

    func testPayloadChecksumMismatchFailsEvenAfterValidMember() throws {
        var data = try F.zip([("Good.csv", F.csv(1)), ("Bad.csv", F.csv(1))], compression: .none)
        let signature = [UInt8](arrayLiteral: 0x50, 0x4b, 0x03, 0x04)
        let first = try F.signature(data, signature)
        let remaining = Data(data.dropFirst(first + 4))
        let second = try F.signature(remaining, signature) + first + 4
        let payload = second + 30 + "Bad.csv".utf8.count
        data[payload] ^= 1
        XCTAssertThrowsError(try F.parse(data, filename: "CRC.zip"))
    }

    func testArchiveResourceLimitsBeforeDecompression() throws {
        XCTAssertThrowsError(try F.parse(F.zip((0..<129).map { ("\($0).csv", Data()) }), filename: "Many.zip"))
        XCTAssertThrowsError(try F.parse(F.zip([("Bomb.csv", Data(repeating: 65, count: 1_000_000))]), filename: "Ratio.zip"))
        let original = try F.zip([("A.csv", F.csv(1))], compression: .none)
        let central = try F.signature(original, [0x50, 0x4b, 0x01, 0x02])
        var oversized = original
        F.put(UInt32(PlaylistImportLimits.entryBytes + 1), in: &oversized, at: central + 24)
        XCTAssertThrowsError(try F.parse(oversized, filename: "Large.zip"))
        // Stored entries stay below ratio/per-entry limits but exceed the total.
        var state: UInt32 = 0x12345678
        let pattern: [UInt8] = (0..<(16 * 1024)).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
        let large = Data((0..<(7 * 1024 * 1024)).map { pattern[$0 % pattern.count] })
        let total = try F.zip((0..<5).map { ("\($0).csv", large) })
        XCTAssertLessThan(total.count, PlaylistImportLimits.inputBytes)
        XCTAssertThrowsError(try PlaylistZIPDirectory(data: total)) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
        }
    }

    func testCancellationDuringArchiveProcessing() async throws {
        let bytes = try F.zip([("A.csv", F.csv(2)), ("B.csv", F.csv(2))])
        let task = Task.detached {
            var processed = 0
            do {
                try PlaylistZIPReader().read(bytes) { _, _ in
                    processed += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("Cancelled archive completed")
            } catch { XCTAssertTrue(error is CancellationError) }
            return processed
        }
        let processed = await task.value
        XCTAssertEqual(processed, 1)
    }

    func testStagingCleansUpOnSuccessFailureAndCancellationAndDoesNotAlterSource() async throws {
        let fixture = try LibraryFixture(count: 0)
        let source = fixture.paths.documents.appendingPathComponent("Source.csv")
        let bytes = F.csv(2); try bytes.write(to: source)
        let importer = F.importer(fixture)
        let report = try await importer.prepare(file: source)
        XCTAssertEqual(report.validCount, 1)
        let staging = PlaylistImportFileAccess(root: fixture.paths.imports)
        XCTAssertThrowsError(try staging.withStagedFile(source: source) { _ in throw CancellationError() })
        XCTAssertThrowsError(try staging.withStagedFile(source: source) { _ in throw PlaylistImportProblem(location: "Synthetic", reason: "Failure") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.prepare(file: source)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.imports.path), [])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try Data("not ZIP".utf8).write(to: fixture.paths.documents.appendingPathComponent("Bad.zip"))
        do { _ = try await importer.prepare(file: fixture.paths.documents.appendingPathComponent("Bad.zip")); XCTFail("Bad archive accepted") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.imports.path), [])
    }
}
