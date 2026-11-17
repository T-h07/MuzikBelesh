import Foundation

/// Byte-state parser: a logical record may span multiple physical lines.
enum PlaylistCSVRecords {
    static func read(_ data: Data, location: String, consume: ([String], Int) throws -> Void) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw PlaylistImportProblem(location: location, reason: "CSV must be UTF-8.") }
        let bytes = [UInt8](data)
        var offset = bytes.starts(with: [239, 187, 191]) ? 3 : 0
        var row: [String] = [], field: [UInt8] = []
        var quoted = false, closed = false, started = false, record = 1
        func fail(_ reason: String) -> PlaylistImportProblem { .init(location: "\(location) — record \(record), column \(row.count + 1)", reason: reason) }
        func finishField() throws {
            guard row.count < PlaylistImportLimits.csvColumns else { throw fail("More than 128 columns.") }
            row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); closed = false
        }
        func finishRecord() throws {
            try finishField()
            guard record <= PlaylistMigrationValidation.maximumEntries + 1 else { throw fail("More than 10,000 occurrences.") }
            try consume(row, record); row.removeAll(keepingCapacity: true); record += 1; started = false
        }
        while offset < bytes.count {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            let byte = bytes[offset]; offset += 1; started = true
            if quoted {
                if byte == 34 {
                    if offset < bytes.count && bytes[offset] == 34 { field.append(34); offset += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(byte) }
            } else {
                switch byte {
                case 34:
                    guard field.isEmpty && !closed else { throw fail("Unexpected quote in an unquoted field.") }; quoted = true
                case 44: try finishField()
                case 10: try finishRecord()
                case 13:
                    guard offset < bytes.count && bytes[offset] == 10 else { throw fail("A carriage return outside quotes must be followed by LF.") }
                    offset += 1; try finishRecord()
                default:
                    guard !closed else { throw fail("Characters after a closing quote.") }; field.append(byte)
                }
            }
            guard field.count <= PlaylistImportLimits.fieldBytes else { throw fail("Field exceeds 16 KiB.") }
        }
        guard !quoted else { throw fail("Unclosed quoted field.") }
        if started || !row.isEmpty || !field.isEmpty || closed { try finishRecord() }
        guard record > 1 else { throw fail("CSV has no header record.") }
    }
}

struct ExportifyCSVParser {
    func parse(_ data: Data, container: String, member: String) throws -> PlaylistImportCandidate {
        let name = try PlaylistImportNormalization.filename((member as NSString).lastPathComponent)
        var headers: [String: Int] = [:], width = 0
        var tracks: [PlaylistMigrationSourceTrack] = [], notes: [String] = []
        try PlaylistCSVRecords.read(data, location: member) { row, record in
            try Task.checkCancellation()
            if record == 1 {
                width = row.count
                for (index, value) in row.enumerated() {
                    let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard headers[key] == nil else { throw PlaylistImportProblem(location: member + " — header", reason: "Duplicate or ambiguous column at index \(index + 1).") }
                    headers[key] = index
                }
                guard headers["track name"] != nil else { throw PlaylistImportProblem(location: member + " — header", reason: "Required Track Name column is missing.") }
                if ["album uri", "artist uri(s)", "album artist name(s)", "isrc", "added at"].contains(where: { headers[$0] != nil }) {
                    notes.append("Artist URIs are used only to disambiguate artist names. Album URI, album artist, ISRC and Added At are recognized but are not stored by the Phase 10.0 source model.")
                }
                return
            }
            let location = "\(member) — record \(record)"
            guard row.count == width else { throw PlaylistImportProblem(location: location, reason: "Column count differs from the header; no rows were imported.") }
            func value(_ key: String) -> String? { headers[key.lowercased()].map { row[$0] } }
            let title = try PlaylistImportNormalization.text(value("Track Name"), field: location + " — Track Name", required: true)!
            let rawArtists = value("Artist Name(s)")
            let artists = try Self.artists(rawArtists, uris: value("Artist URI(s)"), location: location)
            let album = try PlaylistImportNormalization.text(value("Album Name"), field: location + " — Album Name")
            let duration = try PlaylistImportNormalization.duration(value("Track Duration (ms)"), field: location + " — Track Duration (ms)")
            let uri = try PlaylistImportNormalization.text(value("Track URI"), field: location + " — Track URI", limit: 4096)
            let trackID = try PlaylistImportNormalization.spotifyID(uri, kind: "track", field: location + " — Track URI")
            let artwork = PlaylistImportNormalization.artwork(value("Album Image URL"), location: location + " — Album Image URL", notes: &notes)
            tracks.append(.init(position: tracks.count, title: title, primaryArtist: artists.first, additionalArtists: Array(artists.dropFirst()), album: album, durationMs: duration, sourceTrackID: trackID, sourceURI: uri, artworkURL: artwork))
        }
        let source = try PlaylistImportNormalization.finish(.init(source: .exportify, name: name, entries: tracks), container: container, member: member, index: 0)
        return .init(location: member, format: "Exportify CSV", name: name, entryCount: tracks.count, source: source, diagnostics: Array(notes.prefix(50)))
    }
    /// Exportify escapes commas inside names as backslash-comma and joins artists
    /// with comma-space. Require matching artist URIs before treating it as a list.
    static func artists(_ raw: String?, uris: String?, location: String) throws -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var parts: [String] = [], current = ""
        let chars = Array(raw); var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "," { current.append(","); index += 2 }
            else if chars[index] == ",", index + 1 < chars.count, chars[index + 1] == " " { parts.append(current); current = ""; index += 2 }
            else { current.append(chars[index]); index += 1 }
        }
        parts.append(current)
        let identifiers = uris?.components(separatedBy: ", ") ?? []
        let verified = identifiers.count == parts.count && identifiers.allSatisfy { (try? PlaylistImportNormalization.spotifyID($0, kind: "artist", field: location)) != nil }
        let names = verified ? parts : [raw]
        guard names.count <= 50 else { throw PlaylistImportProblem(location: location + " — Artist Name(s)", reason: "More than 50 artists.") }
        return try names.map { try PlaylistImportNormalization.text($0, field: location + " — Artist Name(s)", required: true)! }
    }
}
