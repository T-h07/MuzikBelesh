import Foundation
import GRDB

extension LibraryRepository {
    static func albumTrackIDs(_ albumID: String, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE albumID = ? ORDER BY albumPosition IS NULL, albumPosition, dateAdded, id", arguments: [albumID])
    }

    /// Changes the primary metadata assignment, never track identity or audio.
    static func assignAlbum(_ album: StoredAlbum?, to trackID: String, position: Int?, db: Database) throws {
        guard var track = try StoredTrack.fetchOne(db, key: trackID) else { throw LibraryError.notFound }
        let artist = try album?.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name }
        let performer = try track.artistID.flatMap { try StoredArtist.fetchOne(db, key: $0)?.name } ?? ""
        track.albumID = album?.id; track.albumPosition = position; track.albumArtist = artist
        track.searchText = LibraryIdentity.search([track.title, performer, album?.title ?? "", artist ?? ""].joined(separator: " "))
        track.dateModified = Date()
        try track.update(db)
    }

    static func replaceAlbumTracks(_ ids: [String], album: StoredAlbum, db: Database) throws {
        guard Set(ids).count == ids.count else { throw LibraryError.invalidOrder }
        for id in ids { guard try StoredTrack.fetchOne(db, key: id) != nil else { throw LibraryError.notFound } }
        let previous = try albumTrackIDs(album.id, db: db)
        let included = Set(ids)
        for id in previous where !included.contains(id) { try assignAlbum(nil, to: id, position: nil, db: db) }
        for (position, id) in ids.enumerated() { try assignAlbum(album, to: id, position: position, db: db) }
    }

    @discardableResult func saveAlbum(id: String? = nil, draft: AlbumDraft, trackIDs: [String]? = nil,
                                     artworkPath: String? = nil, replaceArtwork: Bool = false, artworkOperation: String? = nil, createdID: String? = nil) throws -> StoredAlbum {
        let title = try LibraryIdentity.validatedTitle(LibraryIdentity.display(draft.title))
        let description = try LibraryIdentity.validatedDescription(draft.description)
        guard draft.releaseYear.map({ (1...9999).contains($0) }) ?? true else { throw LibraryError.invalidMetadata }
        return try db.write { db in
            var album: StoredAlbum
            if let id {
                guard let current = try StoredAlbum.fetchOne(db, key: id) else { throw LibraryError.notFound }
                album = current
            } else {
                // Names are labels, not identities. Equal names are safe to keep separate.
                album = StoredAlbum(id: createdID ?? UUID().uuidString, title: title, normalizedTitle: LibraryIdentity.normalized(title), artistID: nil, artworkRelativePath: nil, dateAdded: Date(), dateModified: Date())
            }
            album.title = title; album.normalizedTitle = LibraryIdentity.normalized(title)
            album.artistID = try Self.resolveArtist(draft.artist, db: db)
            album.releaseYear = draft.releaseYear; album.description = description
            album.managementSource = "managed"; album.dateModified = Date()
            if replaceArtwork { album.artworkRelativePath = artworkPath }
            try album.save(db)
            let ids = try trackIDs ?? Self.albumTrackIDs(album.id, db: db)
            try Self.replaceAlbumTracks(ids, album: album, db: db)
            if let artworkOperation { try db.execute(sql: "UPDATE library_file_operations SET state = 'committed' WHERE id = ?", arguments: [artworkOperation]) }
            return album
        }
    }
    func addAlbumTracks(_ ids: [String], albumID: String) throws {
        try db.write { db in
            guard let album = try StoredAlbum.fetchOne(db, key: albumID) else { throw LibraryError.notFound }
            var order = try Self.albumTrackIDs(albumID, db: db)
            for id in ids where !order.contains(id) { order.append(id) }
            try Self.replaceAlbumTracks(order, album: album, db: db)
        }
    }
    func removeAlbumTrack(_ id: String, albumID: String) throws {
        try db.write { db in
            guard let album = try StoredAlbum.fetchOne(db, key: albumID) else { throw LibraryError.notFound }
            let order = try Self.albumTrackIDs(albumID, db: db)
            guard order.contains(id) else { throw LibraryError.notFound }
            try Self.replaceAlbumTracks(order.filter { $0 != id }, album: album, db: db)
        }
    }
    func reorderAlbum(_ ids: [String], albumID: String) throws {
        try db.write { db in
            guard let album = try StoredAlbum.fetchOne(db, key: albumID) else { throw LibraryError.notFound }
            let current = try Self.albumTrackIDs(albumID, db: db)
            guard Set(ids) == Set(current), ids.count == current.count else { throw LibraryError.invalidOrder }
            try Self.replaceAlbumTracks(ids, album: album, db: db)
        }
    }
    @discardableResult func deleteAlbum(id: String, confirmed: Bool) throws -> String? {
        guard confirmed else { throw LibraryError.confirmationRequired }
        return try db.write { db in
            guard let album = try StoredAlbum.fetchOne(db, key: id) else { throw LibraryError.notFound }
            try Self.replaceAlbumTracks([], album: album, db: db)
            _ = try StoredAlbum.deleteOne(db, key: id)
            return album.artworkRelativePath
        }
    }
}
