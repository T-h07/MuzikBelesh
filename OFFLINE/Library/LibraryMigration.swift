import Foundation
import GRDB

enum LibraryMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v009_library_management") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "albumArtist", .text)
                t.add(column: "normalizedTitle", .text).notNull().defaults(to: "")
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "playback_state") { t in
                t.add(column: "contextKind", .text)
                t.add(column: "contextSourceID", .text)
            }
            try db.create(table: "library_file_operations") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("ownerID", .text).notNull()
                t.column("originalPath", .text)
                t.column("artworkPath", .text)
                t.column("stagedPath", .text).notNull()
                t.column("state", .text).notNull()
                t.column("dateUpdated", .datetime).notNull()
            }
            try db.create(index: "library_file_operations_owner", on: "library_file_operations", columns: ["ownerID"])
            try db.create(index: "tracks_library_title", on: "tracks", columns: ["normalizedTitle", "id"])
            try db.create(index: "tracks_library_artist", on: "tracks", columns: ["artistID"])
            try db.create(index: "tracks_library_album", on: "tracks", columns: ["albumID"])
            try db.create(index: "tracks_library_date", on: "tracks", columns: ["dateAdded", "id"])
            try db.create(index: "tracks_library_duration", on: "tracks", columns: ["durationMs", "id"])
            try db.create(index: "artists_library_name", on: "artists", columns: ["normalizedName"])
            try db.create(index: "albums_library_title_artist", on: "albums", columns: ["normalizedTitle", "artistID"])
            // Update lookup keys without changing identities or merging existing parents.
            for artist in try StoredArtist.fetchAll(db) {
                try db.execute(sql: "UPDATE artists SET normalizedName = ? WHERE id = ?", arguments: [LibraryIdentity.normalized(artist.name), artist.id])
            }
            for album in try StoredAlbum.fetchAll(db) {
                try db.execute(sql: "UPDATE albums SET normalizedTitle = ? WHERE id = ?", arguments: [LibraryIdentity.normalized(album.title), album.id])
            }
            let rows = try Row.fetchAll(db, sql: "SELECT tracks.id, tracks.title, artists.name AS artist, albums.title AS album FROM tracks LEFT JOIN artists ON artists.id = tracks.artistID LEFT JOIN albums ON albums.id = tracks.albumID")
            for row in rows {
                let title: String = row["title"]
                let artist: String? = row["artist"]; let album: String? = row["album"]
                try db.execute(sql: "UPDATE tracks SET normalizedTitle = ?, searchText = ? WHERE id = ?", arguments: [LibraryIdentity.search(title), LibraryIdentity.search([title, artist ?? "", album ?? ""].joined(separator: " ")), row["id"] as String])
            }
        }
    }
}
