import Foundation

enum PortableLibraryError: LocalizedError, Equatable {
    case fileTooLarge
    case notUTF8
    case malformedJSON
    case duplicateKey(String)
    case nestingTooDeep
    case notALibraryFile
    case newerVersion(Int)
    case unsupportedVersion
    case unsupportedFeatures([String])
    case missingField(String)
    case invalidField(String)
    case limitExceeded(String)
    case invalidReference(String)
    case duplicateIdentifier(String)
    case invalidPositions(String)
    case invalidRecording(String)
    case nothingToExport
    case nothingSelected
    case fileAccess(String)
    case writeFailed
    case operationConflict
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "This library file is larger than the supported 32 MB."
        case .notUTF8: return "This file is not valid UTF-8 text."
        case .malformedJSON: return "This file is damaged or is not a Muzik Belesh library."
        case .duplicateKey(let key): return "This library file contains the field “\(key)” more than once and was not imported."
        case .nestingTooDeep: return "This library file is nested too deeply to be a Muzik Belesh library."
        case .notALibraryFile: return "This is not a Muzik Belesh library file."
        case .newerVersion: return "This library was exported by a newer version of Muzik Belesh. Update the app to import it."
        case .unsupportedVersion: return "This library file uses an unsupported format version."
        case .unsupportedFeatures: return "This library was exported by a newer version of Muzik Belesh and needs features this version does not support."
        case .missingField(let field): return "This library file is missing required information (\(field))."
        case .invalidField(let field): return "This library file contains invalid information (\(field))."
        case .limitExceeded(let detail): return "This library is larger than Muzik Belesh supports: \(detail)."
        case .invalidReference(let detail): return "This library file refers to a song that does not exist (\(detail))."
        case .duplicateIdentifier(let id): return "This library file uses the identifier “\(id)” more than once."
        case .invalidPositions(let playlist): return "Song positions in “\(playlist)” are not in a valid order."
        case .invalidRecording(let detail): return "This library file contains an invalid recording reference (\(detail))."
        case .nothingToExport: return "There is nothing to export. Choose at least one playlist or song."
        case .nothingSelected: return "Choose at least one playlist or include songs that are not in a playlist."
        case .fileAccess(let reason): return reason
        case .writeFailed: return "The library file could not be written. Check available storage and try again."
        case .operationConflict: return "This import was already started with different choices. Open the file again to review it."
        case .storageUnavailable: return "Local library storage is unavailable."
        }
    }
}

/// Untrusted-input codec. Decoding is: bounded size → UTF-8 → structural preflight (depth,
/// duplicate keys) → envelope (format, version, required features) → typed decode → field
/// validation and normalization. A document that fails any step is refused as a whole;
/// nothing is ever partially imported.
enum PortableLibraryCodec {
    static func encode(_ document: PortableLibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> PortableLibraryDocument {
        try Task.checkCancellation()
        guard data.count <= PortableLibraryLimits.inputBytes else { throw PortableLibraryError.fileTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw PortableLibraryError.notUTF8 }
        try PortableJSONPreflight.check(data)
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw PortableLibraryError.notALibraryFile }
        guard envelope.format == PortableLibraryDocument.format else { throw PortableLibraryError.notALibraryFile }
        guard let version = envelope.schemaVersion else { throw PortableLibraryError.missingField("schemaVersion") }
        if version > PortableLibraryDocument.currentSchemaVersion { throw PortableLibraryError.newerVersion(version) }
        guard version == PortableLibraryDocument.currentSchemaVersion else { throw PortableLibraryError.unsupportedVersion }
        let features = envelope.requiredFeatures ?? []
        guard features.count <= PortableLibraryLimits.requiredFeatures else { throw PortableLibraryError.limitExceeded("required features") }
        let unknown = features.filter { !PortableLibraryDocument.supportedFeatures.contains($0) }
        guard unknown.isEmpty else { throw PortableLibraryError.unsupportedFeatures(unknown.map { String($0.prefix(60)) }) }
        let document: PortableLibraryDocument
        do { document = try decoder.decode(PortableLibraryDocument.self, from: data) }
        catch let DecodingError.keyNotFound(key, context) { throw PortableLibraryError.missingField(path(context.codingPath + [key])) }
        catch let DecodingError.valueNotFound(_, context) { throw PortableLibraryError.missingField(path(context.codingPath)) }
        catch let DecodingError.typeMismatch(_, context) { throw PortableLibraryError.invalidField(path(context.codingPath)) }
        catch let DecodingError.dataCorrupted(context) { throw PortableLibraryError.invalidField(path(context.codingPath)) }
        catch { throw PortableLibraryError.malformedJSON }
        return try PortableLibraryValidator.validated(document)
    }

    private struct Envelope: Decodable {
        let format: String?
        let schemaVersion: Int?
        let requiredFeatures: [String]?
    }

    /// Field paths only (no values), so a hostile document cannot inject text into messages.
    private static func path(_ keys: [CodingKey]) -> String {
        let value = keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        let safe = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "[]._".unicodeScalars.contains($0) }
        let text = String(String.UnicodeScalarView(safe)).prefix(80)
        return text.isEmpty ? "document" : String(text)
    }
}

/// Field-by-field validation and normalization (NFC, trimmed, no control characters).
enum PortableLibraryValidator {
    static func validated(_ input: PortableLibraryDocument) throws -> PortableLibraryDocument {
        var document = input
        guard document.format == PortableLibraryDocument.format else { throw PortableLibraryError.notALibraryFile }
        guard document.schemaVersion == PortableLibraryDocument.currentSchemaVersion else { throw PortableLibraryError.unsupportedVersion }
        guard UUID(uuidString: document.exportId) != nil else { throw PortableLibraryError.invalidField("exportId") }
        document.exportId = document.exportId.uppercased()
        document.createdAt = try text(document.createdAt, limit: 40, field: "createdAt")
        if var generator = document.generator {
            generator.app = try text(generator.app, limit: 60, field: "generator.app") ?? "Unknown"
            generator.version = try text(generator.version, limit: 40, field: "generator.version")
            document.generator = generator
        }
        let songs = document.collection.songs, playlists = document.collection.playlists
        guard songs.count <= PortableLibraryLimits.songs else { throw PortableLibraryError.limitExceeded("more than \(PortableLibraryLimits.songs) songs") }
        guard playlists.count <= PortableLibraryLimits.playlists else { throw PortableLibraryError.limitExceeded("more than \(PortableLibraryLimits.playlists) playlists") }
        var songIDs = Set<String>()
        var normalizedSongs: [PortableSong] = []
        normalizedSongs.reserveCapacity(songs.count)
        for (index, value) in songs.enumerated() {
            try Task.checkCancellation()
            var song = value
            try identifier(song.id, field: "songs[\(index)].id")
            guard songIDs.insert(song.id).inserted else { throw PortableLibraryError.duplicateIdentifier(song.id) }
            song.title = try text(song.title, limit: PortableLibraryLimits.titleLength, field: "songs[\(index)].title")
            song.artist = try text(song.artist, limit: PortableLibraryLimits.artistLength, field: "songs[\(index)].artist")
            let extra = song.additionalArtists ?? []
            guard extra.count <= PortableLibraryLimits.additionalArtists else { throw PortableLibraryError.limitExceeded("too many artists for one song") }
            let artists = try extra.enumerated().compactMap { try text($0.element, limit: PortableLibraryLimits.artistLength, field: "songs[\(index)].additionalArtists[\($0.offset)]") }
            song.additionalArtists = artists.isEmpty ? nil : artists
            if var album = song.album {
                guard let title = try text(album.title, limit: PortableLibraryLimits.albumLength, field: "songs[\(index)].album.title") else {
                    throw PortableLibraryError.invalidField("songs[\(index)].album.title")
                }
                album.title = title
                album.artist = try text(album.artist, limit: PortableLibraryLimits.artistLength, field: "songs[\(index)].album.artist")
                if let year = album.releaseYear, !(1000...3000).contains(year) { throw PortableLibraryError.invalidField("songs[\(index)].album.releaseYear") }
                if let position = album.position, !(0...9_999).contains(position) { throw PortableLibraryError.invalidField("songs[\(index)].album.position") }
                song.album = album
            }
            if let duration = song.durationMs, !(0...PortableLibraryLimits.maximumDurationMs).contains(duration) {
                throw PortableLibraryError.invalidField("songs[\(index)].durationMs")
            }
            let references = song.recordings ?? []
            guard references.count <= PortableLibraryLimits.recordingsPerSong else { throw PortableLibraryError.limitExceeded("too many recordings for one song") }
            var kept: [PortableRecordingReference] = []
            for (number, reference) in references.enumerated() {
                // Unknown providers are optional alternatives from a newer exporter: they are
                // ignored and never contacted. A malformed YouTube reference is refused.
                guard reference.provider == PortableRecordingReference.youtube else { continue }
                guard YouTubeURLValidator.isValidID(reference.videoId) else {
                    throw PortableLibraryError.invalidRecording("songs[\(index)].recordings[\(number)]")
                }
                if !kept.contains(reference) { kept.append(reference) }
            }
            song.recordings = kept.isEmpty ? nil : kept
            // A song must be identifiable: a title, or a recording the recipient can inspect.
            guard song.title != nil || !kept.isEmpty else { throw PortableLibraryError.missingField("songs[\(index)].title") }
            normalizedSongs.append(song)
        }
        document.collection.songs = normalizedSongs
        var playlistIDs = Set<String>(), occurrenceIDs = Set<String>()
        var total = 0
        var normalizedPlaylists: [PortablePlaylist] = []
        normalizedPlaylists.reserveCapacity(playlists.count)
        for (index, value) in playlists.enumerated() {
            try Task.checkCancellation()
            var playlist = value
            try identifier(playlist.id, field: "playlists[\(index)].id")
            guard playlistIDs.insert(playlist.id).inserted else { throw PortableLibraryError.duplicateIdentifier(playlist.id) }
            guard let name = try text(playlist.name, limit: PortableLibraryLimits.playlistNameLength, field: "playlists[\(index)].name"),
                  let display = try? LibraryIdentity.validatedName(name) else { throw PortableLibraryError.invalidField("playlists[\(index)].name") }
            playlist.name = display
            playlist.description = try text(playlist.description, limit: PortableLibraryLimits.descriptionLength, field: "playlists[\(index)].description", multiline: true)
            guard playlist.occurrences.count <= PortableLibraryLimits.occurrencesPerPlaylist else {
                throw PortableLibraryError.limitExceeded("“\(playlist.name)” has more than \(PortableLibraryLimits.occurrencesPerPlaylist) songs")
            }
            total += playlist.occurrences.count
            guard total <= PortableLibraryLimits.occurrences else { throw PortableLibraryError.limitExceeded("more than \(PortableLibraryLimits.occurrences) playlist songs in total") }
            for (position, occurrence) in playlist.occurrences.enumerated() {
                try identifier(occurrence.id, field: "playlists[\(index)].occurrences[\(position)].id")
                guard occurrenceIDs.insert(occurrence.id).inserted else { throw PortableLibraryError.duplicateIdentifier(occurrence.id) }
                guard occurrence.position == position else { throw PortableLibraryError.invalidPositions(playlist.name) }
                guard songIDs.contains(occurrence.songRef) else { throw PortableLibraryError.invalidReference("playlists[\(index)].occurrences[\(position)]") }
            }
            normalizedPlaylists.append(playlist)
        }
        document.collection.playlists = normalizedPlaylists
        return document
    }

    static func identifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= PortableLibraryLimits.identifierLength,
              value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f || $0 == 0x2e }) else {
            throw PortableLibraryError.invalidField(field)
        }
    }

    /// Trims, applies NFC and refuses control characters. Empty optional text becomes nil.
    static func text(_ value: String?, limit: Int, field: String, multiline: Bool = false) throws -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !result.isEmpty else { return nil }
        guard result.count <= limit else { throw PortableLibraryError.invalidField(field) }
        for scalar in result.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            if multiline && (scalar == "\n" || scalar == "\t") { continue }
            throw PortableLibraryError.invalidField(field)
        }
        return result
    }
}

/// Byte-level structural preflight: bounded nesting depth and no duplicate object keys
/// (`JSONDecoder` would otherwise silently keep the last value of a repeated key).
struct PortableJSONPreflight {
    private let bytes: [UInt8]
    private var index = 0
    private init(_ data: Data) { bytes = [UInt8](data) }

    static func check(_ data: Data) throws {
        var parser = PortableJSONPreflight(data)
        parser.whitespace()
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw PortableLibraryError.malformedJSON }
    }

    private mutating func whitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }

    private mutating func value(depth: Int) throws {
        guard depth < PortableLibraryLimits.jsonDepth else { throw PortableLibraryError.nestingTooDeep }
        guard index < bytes.count else { throw PortableLibraryError.malformedJSON }
        switch bytes[index] {
        case 0x7b: try object(depth: depth + 1)
        case 0x5b: try array(depth: depth + 1)
        case 0x22: _ = try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6e: try literal("null")
        case 0x2d, 0x30...0x39: number()
        default: throw PortableLibraryError.malformedJSON
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        var keys = Set<String>()
        whitespace()
        if index < bytes.count, bytes[index] == 0x7d { index += 1; return }
        while true {
            whitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw PortableLibraryError.malformedJSON }
            let key = try string()
            guard keys.insert(key).inserted else { throw PortableLibraryError.duplicateKey(String(key.prefix(40))) }
            whitespace()
            guard index < bytes.count, bytes[index] == 0x3a else { throw PortableLibraryError.malformedJSON }
            index += 1
            whitespace()
            try value(depth: depth)
            whitespace()
            guard index < bytes.count else { throw PortableLibraryError.malformedJSON }
            if bytes[index] == 0x2c { index += 1; continue }
            if bytes[index] == 0x7d { index += 1; return }
            throw PortableLibraryError.malformedJSON
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        whitespace()
        if index < bytes.count, bytes[index] == 0x5d { index += 1; return }
        while true {
            whitespace()
            try value(depth: depth)
            whitespace()
            guard index < bytes.count else { throw PortableLibraryError.malformedJSON }
            if bytes[index] == 0x2c { index += 1; continue }
            if bytes[index] == 0x5d { index += 1; return }
            throw PortableLibraryError.malformedJSON
        }
    }

    /// Returns the decoded string (escapes resolved), so `"a"` and `"a"` are the same key.
    private mutating func string() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x20 { throw PortableLibraryError.malformedJSON }
            if byte == 0x5c {
                escaped = true
                index += 2
                continue
            }
            if byte == 0x22 {
                index += 1
                let raw = Data(bytes[start..<index])
                if !escaped { return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self) }
                guard let decoded = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else {
                    throw PortableLibraryError.malformedJSON
                }
                return decoded
            }
            index += 1
        }
        throw PortableLibraryError.malformedJSON
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
            throw PortableLibraryError.malformedJSON
        }
        index += expected.count
    }

    private mutating func number() {
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) || [0x2d, 0x2b, 0x2e, 0x65, 0x45].contains(bytes[index]) { index += 1 }
    }
}
