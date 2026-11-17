import Foundation
import CoreFoundation

enum PlaylistImportNormalization {
    static func text(_ value: Any?, field: String, required: Bool = false, limit: Int = 300) throws -> String? {
        guard let value, !(value is NSNull) else {
            if required { throw PlaylistImportProblem(location: field, reason: "Required text is missing.") }; return nil
        }
        guard let string = value as? String else { throw PlaylistImportProblem(location: field, reason: "Expected text.") }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t\r\n"))
        guard normalized.rangeOfCharacter(from: forbidden) == nil else { throw PlaylistImportProblem(location: field, reason: "Unsupported control character in text.") }
        guard normalized.count <= limit else { throw PlaylistImportProblem(location: field, reason: "Text exceeds \(limit) characters.") }
        if normalized.isEmpty {
            if required { throw PlaylistImportProblem(location: field, reason: "Required text is empty.") }; return nil
        }
        return normalized
    }
    static func duration(_ value: Any?, field: String) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw PlaylistImportProblem(location: field, reason: "Duration must be a nonnegative integer in milliseconds.")
        }
        let raw = (value as? String) ?? (value as? NSNumber)?.stringValue ?? "invalid"
        if raw.isEmpty { return nil }
        guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let duration = Int64(raw), duration >= 0 else {
            throw PlaylistImportProblem(location: field, reason: "Duration must be a nonnegative Int64 in milliseconds.")
        }
        return duration
    }
    static func spotifyID(_ uri: String?, kind: String, field: String) throws -> String? {
        guard let uri else { return nil }
        let parts = uri.components(separatedBy: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == kind, parts[2].count == 22,
              parts[2].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw PlaylistImportProblem(location: field, reason: "Expected a Spotify \(kind) URI; local tracks and episodes are unsupported.")
        }
        return parts[2]
    }
    static func artwork(_ value: Any?, location: String, notes: inout [String]) -> URL? {
        guard let value, !(value is NSNull), (value as? String) != "" else { return nil }
        if let string = value as? String, string.count <= 4096, let url = URL(string: string), MigrationPersistentText.artwork(url) != nil { return url }
        notes.append("\(location) — Optional artwork was discarded: only HTTPS references without credentials, query or fragment are retained.")
        return nil
    }
    static func filename(_ filename: String) throws -> String {
        let stem = (filename as NSString).deletingPathExtension
        let clean = stem.components(separatedBy: .controlCharacters).joined(separator: " ")
        return try LibraryIdentity.validatedName(clean)
    }
    static func finish(_ source: PlaylistMigrationSourcePlaylist, container: String, member: String, index: Int) throws -> PlaylistMigrationSourcePlaylist {
        try PlaylistMigrationValidation.validate(source)
        let reference = try PlaylistImportIdentity.reference(source: source, container: container, member: member, index: index)
        let result = PlaylistMigrationSourcePlaylist(source: source.source, name: source.name, sourcePlaylistID: source.sourcePlaylistID, sourceReference: reference, entries: source.entries)
        try PlaylistMigrationValidation.validate(result)
        return result
    }
}
