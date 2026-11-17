import Foundation

struct SpotifyPlaylistJSONParser {
    func parse(_ data: Data, container: String, member: String, identityMember: String? = nil) throws -> [PlaylistImportCandidate] {
        guard String(data: data, encoding: .utf8) != nil else { throw PlaylistImportProblem(location: member, reason: "Account-data JSON must be UTF-8.") }
        try Self.checkStructureBudget(data, location: member)
        let document: Any
        do { document = try JSONSerialization.jsonObject(with: data) }
        catch { throw PlaylistImportProblem(location: member, reason: "Invalid JSON syntax.") }
        guard let root = document as? [String: Any], let playlists = root["playlists"] as? [Any] else {
            throw PlaylistImportProblem(location: member, reason: "Expected an account-data object with a playlists array. Streaming history and Web API responses are unsupported.")
        }
        guard playlists.count <= PlaylistImportLimits.playlists else {
            throw PlaylistImportProblem(location: member, reason: "More than 100 playlists in one document.")
        }
        return try playlists.enumerated().map { index, raw in
            try Task.checkCancellation()
            let location = "\(member) — $.playlists[\(index)]"
            let object = raw as? [String: Any]
            let displayName = (object?["name"] as? String).map { String($0.prefix(120)) } ?? "Playlist \(index + 1)"
            let count = (object?["items"] as? [Any])?.count
            do {
                guard let object else { throw PlaylistImportProblem(location: location, reason: "Expected a playlist object.") }
                let name = try PlaylistImportNormalization.text(object["name"], field: location + ".name", required: true, limit: 120)!
                guard let items = object["items"] as? [Any] else { throw PlaylistImportProblem(location: location + ".items", reason: "Expected the complete items array.") }
                guard items.count <= PlaylistMigrationValidation.maximumEntries else { throw PlaylistImportProblem(location: location + ".items", reason: "More than 10,000 occurrences.") }
                let playlistURI = try PlaylistImportNormalization.text(object["playlistUri"], field: location + ".playlistUri", limit: 500)
                let playlistID = try PlaylistImportNormalization.spotifyID(playlistURI, kind: "playlist", field: location + ".playlistUri")
                var notes: [String] = []
                var tracks: [PlaylistMigrationSourceTrack] = []
                for (position, rawItem) in items.enumerated() {
                    try Task.checkCancellation()
                    let path = location + ".items[\(position)]"
                    guard let item = rawItem as? [String: Any], let track = item["track"] as? [String: Any],
                          item["episode"] == nil || item["episode"] is NSNull,
                          item["localTrack"] == nil || item["localTrack"] is NSNull else {
                        throw PlaylistImportProblem(location: path, reason: "Unsupported or missing track item (episodes and local-only items cannot be represented).")
                    }
                    if let explicit = item["position"] {
                        guard try PlaylistImportNormalization.duration(explicit, field: path + ".position") == Int64(position) else {
                            throw PlaylistImportProblem(location: path + ".position", reason: "Source position disagrees with the zero-based item order.")
                        }
                    }
                    let title = try PlaylistImportNormalization.text(track["trackName"], field: path + ".track.trackName", required: true)!
                    let artist = try PlaylistImportNormalization.text(track["artistName"], field: path + ".track.artistName")
                    let album = try PlaylistImportNormalization.text(track["albumName"], field: path + ".track.albumName")
                    let uri = try PlaylistImportNormalization.text(track["trackUri"], field: path + ".track.trackUri", limit: 4096)
                    let trackID = try PlaylistImportNormalization.spotifyID(uri, kind: "track", field: path + ".track.trackUri")
                    let duration = try PlaylistImportNormalization.duration(track["durationMs"], field: path + ".track.durationMs")
                    var additional: [String] = []
                    if let value = track["additionalArtists"], !(value is NSNull) {
                        guard let array = value as? [Any], array.count <= 49 else { throw PlaylistImportProblem(location: path + ".track.additionalArtists", reason: "Expected at most 49 artist names.") }
                        additional = try array.enumerated().map { try PlaylistImportNormalization.text($0.element, field: path + ".track.additionalArtists[\($0.offset)]", required: true)! }
                    }
                    let artwork = PlaylistImportNormalization.artwork(track["artworkUrl"], location: path + ".track.artworkUrl", notes: &notes)
                    tracks.append(.init(position: position, title: title, primaryArtist: artist, additionalArtists: additional, album: album, durationMs: duration, sourceTrackID: trackID, sourceURI: uri, artworkURL: artwork))
                }
                let source = try PlaylistImportNormalization.finish(.init(source: .spotifyAccountExport, name: name, sourcePlaylistID: playlistID, entries: tracks), container: container, member: identityMember ?? member, index: index)
                return PlaylistImportCandidate(location: location, format: "Spotify JSON", name: name, entryCount: count, source: source, diagnostics: Array(notes.prefix(50)))
            } catch is CancellationError { throw CancellationError() }
            catch {
                return PlaylistImportCandidate(location: location, format: "Spotify JSON", name: displayName, entryCount: count, source: nil, diagnostics: [Self.message(error, location: location)])
            }
        }
    }
    /// Bound object allocation and nesting before Foundation decodes untrusted JSON.
    /// Syntax and field types are still exclusively validated by the actual decoder.
    private static func checkStructureBudget(_ data: Data, location: String) throws {
        var quoted = false, escaped = false, depth = 0, containers = 0, separators = 0
        for (index, byte) in data.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true }
                else if byte == 91 || byte == 123 { depth += 1; containers += 1 }
                else if byte == 93 || byte == 125 { depth -= 1 }
                else if byte == 44 || byte == 58 { separators += 1 }
                guard depth <= 64, containers <= 50_000, separators <= 500_000 else {
                    throw PlaylistImportProblem(location: location, reason: "JSON exceeds nesting or structural resource limits; split the export into smaller files.")
                }
            }
        }
    }
    static func message(_ error: Error, location: String) -> String {
        if let problem = error as? PlaylistImportProblem { return problem.localizedDescription }
        if let problem = error as? PlaylistMigrationFoundationError { return "\(location) — \(problem.localizedDescription) This playlist was not imported." }
        if let problem = error as? LibraryError { return "\(location) — \(problem.localizedDescription) This playlist was not imported." }
        return "\(location) — Metadata could not be validated. This playlist was not imported."
    }
}
