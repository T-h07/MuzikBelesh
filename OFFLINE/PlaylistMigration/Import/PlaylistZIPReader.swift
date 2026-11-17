import Foundation
import ZIPFoundation

/// Strict metadata preflight, not a decompressor. ZIPFoundation alone decompresses.
/// Classic single-disk ZIP with stored/deflate members is sufficient for these exports.
struct PlaylistZIPDirectory {
    struct Member {
        let path: String
        let compressed: Int
        let expanded: Int
        let crc: UInt32
        let directory: Bool
    }
    let members: [Member]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        var location = "ZIP archive"
        func fail(_ reason: String) -> PlaylistImportProblem { .init(location: location, reason: reason) }
        func integer(_ at: Int, _ length: Int) throws -> Int {
            guard at >= 0, length > 0, at <= bytes.count - length else { throw fail("Truncated ZIP metadata.") }
            return (0..<length).reduce(0) { $0 | (Int(bytes[at + $1]) << ($1 * 8)) }
        }
        func slice(_ at: Int, _ length: Int) throws -> [UInt8] {
            guard at >= 0, length >= 0, at <= bytes.count - length else { throw fail("Truncated ZIP member name or extra data.") }
            return Array(bytes[at..<(at + length)])
        }
        func extras(_ at: Int, _ length: Int) throws {
            _ = try slice(at, length)
            var cursor = at
            while cursor < at + length {
                guard cursor + 4 <= at + length else { throw fail("Malformed ZIP extra fields.") }
                let tag = try integer(cursor, 2), size = try integer(cursor + 2, 2)
                // ZIP64, Unicode path override and strong encryption can change interpretation.
                guard ![0x0001, 0x7075, 0x0017, 0x9901].contains(tag), cursor + 4 + size <= at + length else { throw fail("Unsupported or malformed ZIP extra fields.") }
                cursor += 4 + size
            }
        }
        guard bytes.count >= 22, bytes.count <= PlaylistImportLimits.inputBytes else { throw fail("ZIP input is truncated or exceeds 20 MiB.") }
        var end: Int?
        for position in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try integer(position, 4) == 0x06054b50, try position + 22 + integer(position + 20, 2) == bytes.count { end = position; break }
        }
        guard let end else { throw fail("ZIP end-of-directory record is missing or corrupt.") }
        let count = try integer(end + 10, 2), size = try integer(end + 12, 4), start = try integer(end + 16, 4)
        guard try integer(end + 4, 2) == 0, try integer(end + 6, 2) == 0,
              try integer(end + 8, 2) == count, count <= PlaylistImportLimits.members,
              start + size == end else { throw fail("Split/ZIP64 archives, more than 128 members, or inconsistent directories are unsupported.") }
        var cursor = start, total = 0, parsed: [Member] = [], ranges: [Range<Int>] = []
        var names: [String: Bool] = [:]
        for memberIndex in 0..<count {
            try Task.checkCancellation()
            location = "ZIP member \(memberIndex + 1)"
            guard try integer(cursor, 4) == 0x02014b50 else { throw fail("Corrupt central directory.") }
            let flags = try integer(cursor + 8, 2), method = try integer(cursor + 10, 2)
            let crc = try integer(cursor + 16, 4), compressed = try integer(cursor + 20, 4), expanded = try integer(cursor + 24, 4)
            let nameSize = try integer(cursor + 28, 2), extraSize = try integer(cursor + 30, 2), commentSize = try integer(cursor + 32, 2)
            let attributes = try integer(cursor + 38, 4), local = try integer(cursor + 42, 4)
            guard try integer(cursor + 6, 2) <= 20, flags & ~0x0808 == 0, [0, 8].contains(method),
                  try integer(cursor + 34, 2) == 0 else { throw fail("Encrypted entries, unsupported flags/compression or split archives are not accepted.") }
            let nameBytes = try slice(cursor + 46, nameSize)
            guard let path = String(bytes: nameBytes, encoding: .utf8), !path.isEmpty, path.utf8.count <= 1024 else { throw fail("ZIP member names must be UTF-8 and at most 1,024 bytes.") }
            let directory = path.hasSuffix("/")
            let clean = directory ? String(path.dropLast()) : path
            let components = clean.components(separatedBy: "/")
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  path.rangeOfCharacter(from: .controlCharacters) == nil,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(" ") && !$0.hasSuffix(".") }) else {
                throw fail("Unsafe member path (absolute, traversal, backslash or ambiguous component).")
            }
            location = path
            let mode = (attributes >> 16) & 0xf000
            guard mode == 0 || mode == (directory ? 0x4000 : 0x8000),
                  attributes & 0x10 == 0 || directory else { throw fail("Symlinks, special files and conflicting directory attributes are unsupported.") }
            let key = clean.precomposedStringWithCanonicalMapping.lowercased()
            guard names[key] == nil else { throw fail("Duplicate or conflicting member names.") }
            names[key] = directory
            guard expanded <= PlaylistImportLimits.entryBytes, compressed <= PlaylistImportLimits.inputBytes,
                  expanded <= max(1, compressed) * PlaylistImportLimits.compressionRatio,
                  method != 0 || compressed == expanded,
                  !directory || (expanded == 0 && compressed == 0 && crc == 0) else { throw fail("Member exceeds 8 MiB, 200:1 compression ratio, or has inconsistent sizes.") }
            total += expanded
            guard total <= PlaylistImportLimits.expandedBytes else { throw fail("Total expanded data exceeds 32 MiB.") }
            let ext = (path as NSString).pathExtension.lowercased()
            guard !["zip", "zipx", "gz", "tgz", "tar", "7z", "rar"].contains(ext) else { throw fail("Nested archives are unsupported.") }
            try extras(cursor + 46 + nameSize, extraSize)
            cursor += 46 + nameSize + extraSize + commentSize
            guard cursor <= end else { throw fail("Central directory exceeds its declared bounds.") }
            guard try integer(local, 4) == 0x04034b50,
                  try integer(local + 4, 2) <= 20,
                  try integer(local + 6, 2) == flags, try integer(local + 8, 2) == method else { throw fail("Local and central headers disagree.") }
            let localNameSize = try integer(local + 26, 2), localExtraSize = try integer(local + 28, 2)
            guard try slice(local + 30, localNameSize) == nameBytes else { throw fail("Local and central member paths disagree.") }
            try extras(local + 30 + localNameSize, localExtraSize)
            var localEnd = local + 30 + localNameSize + localExtraSize + compressed
            if flags & 8 == 0 {
                guard try integer(local + 14, 4) == crc, try integer(local + 18, 4) == compressed,
                      try integer(local + 22, 4) == expanded else { throw fail("Local and central sizes or checksums disagree.") }
            } else {
                for (offset, expected) in [(14, crc), (18, compressed), (22, expanded)] {
                    let value = try integer(local + offset, 4)
                    guard value == 0 || value == expected else { throw fail("Invalid local descriptor metadata.") }
                }
                if try integer(localEnd, 4) == 0x08074b50 { localEnd += 4 }
                guard try integer(localEnd, 4) == crc, try integer(localEnd + 4, 4) == compressed,
                      try integer(localEnd + 8, 4) == expanded else { throw fail("ZIP data descriptor disagrees with the central directory.") }
                localEnd += 12
            }
            guard local >= 0, localEnd <= start else { throw fail("Member data overlaps the central directory.") }
            ranges.append(local..<localEnd)
            parsed.append(Member(path: path, compressed: compressed, expanded: expanded, crc: UInt32(crc), directory: directory))
        }
        location = "ZIP archive"
        guard cursor == end else { throw fail("Central directory member count or size mismatch.") }
        var next = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == next else { throw fail("Overlapping members, unexplained data or self-extracting ZIP prefix.") }
            next = range.upperBound
        }
        guard next == start else { throw fail("Unaccounted ZIP member data.") }
        for path in names.keys {
            let parts = path.components(separatedBy: "/")
            for length in 1..<parts.count {
                guard names[parts.prefix(length).joined(separator: "/")] != false else { throw fail("File/directory member path conflict.") }
            }
        }
        members = parsed
    }
}

struct PlaylistZIPReader {
    func read(_ data: Data, consume: (String, Data) throws -> Void) throws {
        let directory = try PlaylistZIPDirectory(data: data)
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read, pathEncoding: .utf8) }
        catch { throw PlaylistImportProblem(location: "ZIP archive", reason: "ZIPFoundation could not open this archive.") }
        let entries = Array(archive)
        guard entries.count == directory.members.count else { throw PlaylistImportProblem(location: "ZIP archive", reason: "Archive member enumeration is incomplete.") }
        var total = 0
        for (entry, member) in zip(entries, directory.members) {
            try Task.checkCancellation()
            guard entry.path == member.path, entry.compressedSize == UInt64(member.compressed),
                  entry.uncompressedSize == UInt64(member.expanded), entry.checksum == member.crc,
                  entry.type == (member.directory ? .directory : .file) else {
                throw PlaylistImportProblem(location: member.path, reason: "Archive metadata interpretations disagree.")
            }
            var output = Data()
            do {
                let checksum = try archive.extract(entry, bufferSize: 32 * 1024, skipCRC32: false) { chunk in
                    try Task.checkCancellation()
                    guard output.count + chunk.count <= member.expanded,
                          total + chunk.count <= PlaylistImportLimits.expandedBytes else {
                        throw PlaylistImportProblem(location: member.path, reason: "Decompression exceeds declared size or resource limits.")
                    }
                    output.append(chunk); total += chunk.count
                }
                guard output.count == member.expanded, checksum == member.crc else {
                    throw PlaylistImportProblem(location: member.path, reason: "Extracted size or CRC32 checksum mismatch.")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let problem as PlaylistImportProblem { throw problem }
            catch { throw PlaylistImportProblem(location: member.path, reason: "Corrupt or unsupported compressed data.") }
            guard !output.starts(with: [0x50, 0x4b, 0x03, 0x04]), !output.starts(with: [0x50, 0x4b, 0x05, 0x06]) else {
                throw PlaylistImportProblem(location: member.path, reason: "Nested ZIP data is unsupported.")
            }
            if !member.directory { try consume(member.path, output) }
        }
    }
}
