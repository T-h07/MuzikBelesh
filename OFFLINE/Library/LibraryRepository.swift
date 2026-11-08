import Foundation
import GRDB

final class LibraryRepository {
    let db: DatabaseQueue
    init(db: DatabaseQueue) { self.db = db }

    static func tracks(_ db: Database, query: String = "", sort: LibrarySort = .newest) throws -> [StoredTrack] {
        let term = LibraryIdentity.search(String(query.prefix(500)))
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        // Only the enum's fixed ORDER BY fragments are interpolated; input is bound.
        return try StoredTrack.fetchAll(db, sql: """
            SELECT tracks.* FROM tracks LEFT JOIN artists ON artists.id = tracks.artistID
            WHERE (? = '' OR tracks.searchText LIKE ? ESCAPE '\\')
            ORDER BY \(sort.sqlOrder)
            """, arguments: [term, "%\(term)%"])
    }
    func search(_ query: String, sort: LibrarySort) throws -> [StoredTrack] { try db.read { try Self.tracks($0, query: query, sort: sort) } }
    static func snapshot(_ db: Database) throws -> LibrarySnapshot {
        let setting = try StoredSetting.fetchOne(db, key: "librarySort")?.value
        let sort = setting.flatMap(LibrarySort.init(rawValue:)) ?? .newest
        var result = LibrarySnapshot()
        result.sort = sort
        result.tracks = try tracks(db, sort: sort)
        result.artists = try StoredArtist.fetchAll(db)
        result.albums = try StoredAlbum.fetchAll(db)
        result.playlists = try StoredPlaylist.order(Column("dateAdded"), Column("id")).fetchAll(db)
        result.memberships = try PlaylistMembership.order(Column("playlistID"), Column("position")).fetchAll(db)
        result.migrationSessions = try GRDBPlaylistMigrationRepository.sessions(db)
        result.migrationEntries = try GRDBPlaylistMigrationRepository.entries(db)
        result.likedIDs = Set(try String.fetchAll(db, sql: "SELECT trackID FROM liked_tracks"))
        result.recentIDs = try String.fetchAll(db, sql: "SELECT trackID FROM playback_history GROUP BY trackID ORDER BY MAX(startedAt) DESC, trackID LIMIT 20")
        return result
    }
    func snapshot() throws -> LibrarySnapshot { try db.read(Self.snapshot) }
    func setSort(_ sort: LibrarySort) throws {
        try db.write { try StoredSetting(key: "librarySort", value: sort.rawValue, valueType: "string", dateModified: Date()).save($0) }
    }
    func setLiked(_ liked: Bool, trackID: String) throws {
        try db.write { db in
            if liked {
                guard try StoredTrack.fetchOne(db, key: trackID) != nil else { throw LibraryError.notFound }
                try db.execute(sql: "INSERT OR IGNORE INTO liked_tracks (trackID, dateLiked) VALUES (?, ?)", arguments: [trackID, Date()])
            } else { try db.execute(sql: "DELETE FROM liked_tracks WHERE trackID = ?", arguments: [trackID]) }
        }
    }

    @discardableResult func createPlaylist(name: String, description: String = "") throws -> StoredPlaylist {
        let now = Date()
        let playlist = StoredPlaylist(id: UUID().uuidString, name: try LibraryIdentity.validatedName(name), description: try LibraryIdentity.validatedDescription(description), artworkRelativePath: nil, dateAdded: now, dateModified: now)
        try db.write { try playlist.insert($0) }
        return playlist
    }
    func updatePlaylist(id: String, name: String, description: String) throws {
        let name = try LibraryIdentity.validatedName(name)
        try db.write { db in
            guard var playlist = try StoredPlaylist.fetchOne(db, key: id) else { throw LibraryError.notFound }
            playlist.name = name; playlist.description = try LibraryIdentity.validatedDescription(description); playlist.dateModified = Date()
            try playlist.update(db)
        }
    }
    func deletePlaylist(id: String, confirmed: Bool) throws -> String? {
        guard confirmed else { throw LibraryError.confirmationRequired }
        return try db.write { db in
            guard let playlist = try StoredPlaylist.fetchOne(db, key: id) else { throw LibraryError.notFound }
            _ = try StoredPlaylist.deleteOne(db, key: id)
            return playlist.artworkRelativePath
        }
    }
    static func replaceMembership(_ ids: [String], playlistID: String, db: Database) throws {
        guard try StoredPlaylist.fetchOne(db, key: playlistID) != nil else { throw LibraryError.notFound }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_migrations WHERE destinationPlaylistID = ?", arguments: [playlistID]) == 0 else { throw PlaylistMigrationStorageError.managedPlaylist }
        guard Set(ids).count == ids.count else { throw LibraryError.invalidOrder }
        for id in ids { guard try StoredTrack.fetchOne(db, key: id) != nil else { throw LibraryError.notFound } }
        try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlistID = ?", arguments: [playlistID])
        for (position, id) in ids.enumerated() {
            try db.execute(sql: "INSERT INTO playlist_tracks (playlistID, trackID, position, dateAdded) VALUES (?, ?, ?, ?)", arguments: [playlistID, id, position, Date()])
        }
        try db.execute(sql: "UPDATE playlists SET dateModified = ? WHERE id = ?", arguments: [Date(), playlistID])
    }
    func addTracks(_ ids: [String], playlistID: String) throws {
        try db.write { db in
            var order = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [playlistID])
            for id in ids where !order.contains(id) { order.append(id) }
            try Self.replaceMembership(order, playlistID: playlistID, db: db)
        }
    }
    func removeTrack(_ id: String, playlistID: String) throws {
        try db.write { db in
            let order = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [playlistID]).filter { $0 != id }
            try Self.replaceMembership(order, playlistID: playlistID, db: db)
        }
    }
    func reorder(_ ids: [String], playlistID: String) throws {
        try db.write { db in
            let current = try String.fetchAll(db, sql: "SELECT trackID FROM playlist_tracks WHERE playlistID = ? ORDER BY position", arguments: [playlistID])
            guard Set(ids) == Set(current), ids.count == current.count else { throw LibraryError.invalidOrder }
            try Self.replaceMembership(ids, playlistID: playlistID, db: db)
        }
    }
    static func resolveArtist(_ value: String, db: Database) throws -> String? {
        let name = LibraryIdentity.display(value)
        guard !name.isEmpty else { return nil }
        guard name.count <= 300 else { throw LibraryError.invalidMetadata }
        let normalized = LibraryIdentity.normalized(name)
        if let id = try String.fetchOne(db, sql: "SELECT id FROM artists WHERE normalizedName = ? ORDER BY id LIMIT 1", arguments: [normalized]) { return id }
        let id = LibraryIdentity.id("artist", [normalized]); let now = Date()
        try StoredArtist(id: id, name: name, normalizedName: normalized, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
        return id
    }
    static func resolveAlbum(_ value: String, artistID: String?, db: Database) throws -> String? {
        let title = LibraryIdentity.display(value)
        guard !title.isEmpty else { return nil }
        guard title.count <= 300 else { throw LibraryError.invalidMetadata }
        let normalized = LibraryIdentity.normalized(title)
        // Imports can reuse an unambiguous imported parent, never silently merge
        // into a separately managed album with the same display name.
        let matches = try String.fetchAll(db, sql: "SELECT id FROM albums WHERE normalizedTitle = ? AND artistID IS ? AND managementSource IS NULL ORDER BY id", arguments: [normalized, artistID])
        if matches.count == 1 { return matches[0] }
        let id = UUID().uuidString; let now = Date()
        try StoredAlbum(id: id, title: title, normalizedTitle: normalized, artistID: artistID, artworkRelativePath: nil, dateAdded: now, dateModified: now).insert(db)
        return id
    }
    func editMetadata(trackID: String, draft: TrackMetadataDraft, artworkPath: String? = nil, replaceArtwork: Bool = false, artworkOperation: String? = nil) throws {
        let title = try LibraryIdentity.validatedTitle(draft.title)
        try db.write { db in
            guard var track = try StoredTrack.fetchOne(db, key: trackID) else { throw LibraryError.notFound }
            let artistID = try Self.resolveArtist(draft.artist, db: db)
            let albumArtist = LibraryIdentity.display(draft.albumArtist)
            let albumArtistID = albumArtist.isEmpty ? artistID : try Self.resolveArtist(albumArtist, db: db)
            let previousAlbum = try track.albumID.flatMap { try StoredAlbum.fetchOne(db, key: $0) }
            let unchanged = previousAlbum.map {
                $0.normalizedTitle == LibraryIdentity.normalized(draft.album) &&
                ($0.artistID == albumArtistID || ($0.artistID == nil && albumArtist.isEmpty))
            } ?? false
            let albumID = try unchanged ? track.albumID : Self.resolveAlbum(draft.album, artistID: albumArtistID, db: db)
            if albumID != track.albumID {
                track.albumPosition = try albumID.map { id in (try Int.fetchOne(db, sql: "SELECT MAX(albumPosition) FROM tracks WHERE albumID = ?", arguments: [id]) ?? -1) + 1 }
            }
            track.title = title; track.artistID = artistID; track.albumID = albumID
            track.albumArtist = albumArtist.isEmpty ? nil : albumArtist
            track.normalizedTitle = LibraryIdentity.search(title)
            track.searchText = LibraryIdentity.search([title, draft.artist, draft.album, albumArtist].joined(separator: " "))
            track.dateModified = Date(); track.metadataSource = "local_edit"
            if replaceArtwork { track.artworkRelativePath = artworkPath }
            try track.update(db)
            if let artworkOperation { try db.execute(sql: "UPDATE library_file_operations SET state = 'committed' WHERE id = ?", arguments: [artworkOperation]) }
        }
    }
    static func sourceTrack(type: String, identifier: String, db: Database) throws -> StoredTrack? {
        try StoredTrack.fetchOne(db, sql: "SELECT tracks.* FROM tracks JOIN track_sources ON tracks.id = track_sources.trackID WHERE sourceType = ? AND sourceIdentifier = ? ORDER BY dateRecorded, track_sources.id LIMIT 1", arguments: [type, identifier])
    }
    static func recordSource(trackID: String, type: String?, identifier: String?, db: Database) throws {
        guard let type, let identifier, !type.isEmpty, !identifier.isEmpty else { return }
        if let existing = try sourceTrack(type: type, identifier: identifier, db: db) {
            guard existing.id == trackID else { throw StorageError.duplicate(trackID: existing.id) }
            return
        }
        try StoredTrackSource(id: UUID().uuidString, trackID: trackID, sourceType: type, sourceIdentifier: identifier, canonicalURL: nil, dateRecorded: Date()).insert(db)
    }
}
