import CryptoKit
import Foundation
import GRDB

// MARK: - File access

/// Reads a user-selected or Open-in `.mbelesh` document: security-scoped, coordinated,
/// regular files only, bounded to `PortableLibraryLimits.inputBytes` while reading (the
/// declared size is never trusted). Nothing is written to the library here.
enum PortableLibraryFileReader {
    static func read(_ source: URL) throws -> Data {
        try Task.checkCancellation()
        guard source.isFileURL else { throw PortableLibraryError.fileAccess("Choose a library file stored on this iPhone or in Files.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, failure: Error?, result: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw PortableLibraryError.fileAccess("Choose a library file, not a folder or link.")
                }
                guard (values.fileSize ?? 0) <= PortableLibraryLimits.inputBytes else { throw PortableLibraryError.fileTooLarge }
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                var data = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    guard data.count + chunk.count <= PortableLibraryLimits.inputBytes else { throw PortableLibraryError.fileTooLarge }
                    data.append(chunk)
                }
                result = data
            } catch { failure = error }
        }
        if let failure {
            if failure is CancellationError || failure is PortableLibraryError { throw failure }
            throw PortableLibraryError.fileAccess("This file could not be read. Download it in Files and try again.")
        }
        guard coordinationError == nil, let result else {
            throw PortableLibraryError.fileAccess("Files could not open this document. Download it in Files and try again.")
        }
        return result
    }

    /// A display name for the document, without path components or control characters.
    static func displayName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let clean = base.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? "Muzik Belesh library" : clean).prefix(120))
    }
}

// MARK: - Preview

enum PortableDuplicate: Equatable, Sendable {
    case none
    /// A playlist with exactly the same songs in the same order already exists.
    case identical(existingName: String)
    /// A playlist with this name exists but its contents differ.
    case sameName
}

struct PortableImportPlaylistOption: Identifiable, Equatable, Sendable {
    /// Document-scoped playlist identity (`p1`, …).
    let id: String
    let originalName: String
    let description: String?
    let occurrences: Int
    let uniqueSongs: Int
    let songsWithRecordings: Int
    let fingerprint: String
    let duplicate: PortableDuplicate
    /// First song titles for the expandable list (never more than 200).
    let songTitles: [String]
}

/// The user's choices for one playlist. Nothing is ever overwritten: a duplicate is
/// skipped, imported as a separate copy, or imported under another name.
struct PortableImportSelection: Equatable, Sendable {
    var included: Bool
    var name: String
}

struct PortableImportPreview: Identifiable, Sendable {
    /// One operation identity per preview: repeating the same confirmation (double tap,
    /// relaunch mid-commit) never creates duplicate playlists.
    let id: String
    let documentName: String
    let document: PortableLibraryDocument
    let summary: PortableLibrarySummary
    let playlists: [PortableImportPlaylistOption]
    let unassignedSongs: Int
    let unassignedTitles: [String]
    /// Songs whose referenced recording is already downloaded in this library.
    let alreadyAvailable: Int
    /// Songs whose title and artist exactly match a song already in this library.
    let likelyAvailable: Int

    var defaultSelections: [String: PortableImportSelection] {
        var names = Set<String>()
        var result: [String: PortableImportSelection] = [:]
        for option in playlists {
            switch option.duplicate {
            case .none: result[option.id] = .init(included: true, name: option.originalName)
            case .identical: result[option.id] = .init(included: false, name: PortableImportNames.copyName(option.originalName, taken: names))
            case .sameName: result[option.id] = .init(included: true, name: PortableImportNames.copyName(option.originalName, taken: names))
            }
            names.insert(LibraryIdentity.search(result[option.id]!.name))
        }
        return result
    }
}

enum PortableImportNames {
    static let unassignedCollection = "Imported Songs"

    /// "Name (2)", "Name (3)", … bounded to the playlist name limit.
    static func copyName(_ name: String, taken: Set<String> = []) -> String {
        for number in 2...999 {
            let suffix = " (\(number))"
            let candidate = String(name.prefix(PortableLibraryLimits.playlistNameLength - suffix.count)) + suffix
            if !taken.contains(LibraryIdentity.search(candidate)) { return candidate }
        }
        return String(name.prefix(PortableLibraryLimits.playlistNameLength))
    }
}

struct PortableLibraryImportPlanner: Sendable {
    let db: DatabaseQueue

    func preview(data: Data, documentName: String) async throws -> PortableImportPreview {
        let document = try await Task.detached(priority: .userInitiated) { try PortableLibraryCodec.decode(data) }.value
        try Task.checkCancellation()
        let local = try await LocalContent.read(db)
        let songs = Dictionary(uniqueKeysWithValues: document.collection.songs.map { ($0.id, $0) })
        var options: [PortableImportPlaylistOption] = []
        for playlist in document.collection.playlists {
            let fingerprint = PortableFingerprint.playlist(playlist, songs: songs)
            let refs = playlist.occurrences.map(\.songRef)
            let unique = Set(refs)
            let duplicate: PortableDuplicate
            if let existing = local.fingerprints[fingerprint] { duplicate = .identical(existingName: existing) }
            else if local.names.contains(LibraryIdentity.search(playlist.name)) { duplicate = .sameName }
            else { duplicate = .none }
            options.append(PortableImportPlaylistOption(id: playlist.id, originalName: playlist.name, description: playlist.description,
                occurrences: refs.count, uniqueSongs: unique.count,
                songsWithRecordings: unique.filter { !(songs[$0]?.recordings ?? []).isEmpty }.count,
                fingerprint: fingerprint, duplicate: duplicate,
                songTitles: refs.prefix(200).map { Self.title(songs[$0]) }))
        }
        let referenced = Set(document.collection.playlists.flatMap { $0.occurrences.map(\.songRef) })
        let unassigned = document.collection.songs.filter { !referenced.contains($0.id) }
        var available = 0, likely = 0
        for song in document.collection.songs {
            if (song.recordings ?? []).contains(where: { local.videos.contains($0.videoId) }) { available += 1 }
            else if let key = Self.identity(song), local.identities.contains(key) { likely += 1 }
        }
        return PortableImportPreview(id: UUID().uuidString, documentName: documentName, document: document,
            summary: PortableLibrarySummary(document, encodedBytes: data.count), playlists: options,
            unassignedSongs: unassigned.count, unassignedTitles: unassigned.prefix(200).map { Self.title($0) },
            alreadyAvailable: available, likelyAvailable: likely)
    }

    static func title(_ song: PortableSong?) -> String {
        guard let song else { return "Unknown song" }
        if let title = song.title { return song.artist.map { title + " — " + $0 } ?? title }
        return song.recordings?.first.map { "YouTube video " + $0.videoId } ?? "Unknown song"
    }

    static func identity(_ song: PortableSong) -> String? {
        guard let title = song.title, let artist = song.artist else { return nil }
        return LibraryIdentity.search(title) + "\u{1f}" + LibraryIdentity.search(artist)
    }

    /// What this library already holds, for duplicate warnings and availability estimates.
    struct LocalContent {
        var fingerprints: [String: String] = [:]
        var names = Set<String>()
        var videos = Set<String>()
        var identities = Set<String>()

        static func read(_ db: DatabaseQueue) async throws -> LocalContent {
            var result = LocalContent()
            // The exporter's visible-order snapshot gives every local playlist's canonical
            // content fingerprint, so a re-shared playlist is recognized by its contents.
            if let plan = try? await PortableLibraryExporter(db: db).plan(.library) {
                let songs = Dictionary(uniqueKeysWithValues: plan.document.collection.songs.map { ($0.id, $0) })
                for (playlist, summary) in zip(plan.document.collection.playlists, plan.playlists) {
                    let fingerprint = PortableFingerprint.playlist(playlist, songs: songs)
                    if result.fingerprints[fingerprint] == nil { result.fingerprints[fingerprint] = summary.name }
                }
            }
            let exported = result.fingerprints
            return try await db.read { db in
                var result = LocalContent()
                result.fingerprints = exported
                for name in try String.fetchAll(db, sql: "SELECT name FROM playlists") { result.names.insert(LibraryIdentity.search(name)) }
                // Fingerprints of earlier imports whose playlist still exists (cheap, and
                // covers playlists too large for a full export).
                for row in try Row.fetchAll(db, sql: """
                    SELECT i.contentFingerprint, p.name FROM portable_library_import_items i
                    JOIN playlist_migrations m ON m.id = i.migrationID JOIN playlists p ON p.id = m.destinationPlaylistID
                    WHERE i.kind = 'playlist'
                    """) {
                    let fingerprint: String = row["contentFingerprint"]
                    if result.fingerprints[fingerprint] == nil { result.fingerprints[fingerprint] = row["name"] }
                }
                result.videos = Set(try String.fetchAll(db, sql: """
                    SELECT DISTINCT s.sourceIdentifier FROM track_sources s JOIN tracks t ON t.id = s.trackID
                    WHERE s.sourceType = 'youtube' AND s.sourceIdentifier IS NOT NULL
                    """))
                for row in try Row.fetchAll(db, sql: "SELECT t.title, a.name AS artist FROM tracks t LEFT JOIN artists a ON a.id = t.artistID") {
                    guard let artist: String = row["artist"] else { continue }
                    result.identities.insert(LibraryIdentity.search(row["title"] as String) + "\u{1f}" + LibraryIdentity.search(artist))
                }
                return result
            }
        }
    }
}

// MARK: - Commit

struct PortableImportRequest: Equatable, Sendable {
    /// Document playlist ID → destination name, for included playlists only.
    var playlists: [String: String]
    var includeUnassigned: Bool
    var automaticAcquisition: Bool

    init(preview: PortableImportPreview, selections: [String: PortableImportSelection], includeUnassigned: Bool, automaticAcquisition: Bool) {
        var chosen: [String: String] = [:]
        for option in preview.playlists {
            guard let selection = selections[option.id], selection.included else { continue }
            chosen[option.id] = selection.name
        }
        playlists = chosen
        self.includeUnassigned = includeUnassigned && preview.unassignedSongs > 0
        self.automaticAcquisition = automaticAcquisition
    }

    func fingerprint(exportID: String) -> String {
        var hash = SHA256()
        let parts = ["muzik-belesh-import-request-v1", exportID, includeUnassigned ? "1" : "0", automaticAcquisition ? "1" : "0"]
            + playlists.keys.sorted().flatMap { [$0, playlists[$0]!] }
        for part in parts { hash.update(data: Data(part.utf8)); hash.update(data: Data([0])) }
        return "mbir-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct PortableImportCommit: Equatable, Sendable {
    let importID: String
    let migrationIDs: [UUID]
    let playlistIDs: [String]
    let reused: Bool
}

struct PortableLibraryImportRepository: Sendable {
    let db: DatabaseQueue
    var now: @Sendable () -> Date = { Date() }

    /// One write transaction creates every selected playlist, every occurrence placeholder and
    /// the import bookkeeping. Nothing is visible until all of it commits; any failure leaves
    /// the library unchanged. Repeating the same operation returns the original result.
    func commit(_ preview: PortableImportPreview, request: PortableImportRequest) async throws -> PortableImportCommit {
        let document = preview.document
        guard !request.playlists.isEmpty || request.includeUnassigned else { throw PortableLibraryError.nothingSelected }
        let requestFingerprint = request.fingerprint(exportID: document.exportId)
        let plans = try Self.sources(preview, request: request)
        let stamp = now()
        return try await db.write { db in
            if let existing = try PortableLibraryImportRecord.filter(Column("operationID") == preview.id).fetchOne(db) {
                guard existing.requestFingerprint == requestFingerprint else { throw PortableLibraryError.operationConflict }
                let items = try PortableLibraryImportItemRecord.filter(Column("importID") == existing.id).order(Column("ordinal")).fetchAll(db)
                let playlists = try items.map { item in
                    try String.fetchOne(db, sql: "SELECT destinationPlaylistID FROM playlist_migrations WHERE id = ?", arguments: [item.migrationID]) ?? ""
                }
                return PortableImportCommit(importID: existing.id, migrationIDs: items.compactMap { UUID(uuidString: $0.migrationID) },
                                            playlistIDs: playlists, reused: true)
            }
            let importID = UUID().uuidString
            try PortableLibraryImportRecord(id: importID, operationID: preview.id, requestFingerprint: requestFingerprint,
                exportID: document.exportId, documentName: String(preview.documentName.prefix(255)), schemaVersion: document.schemaVersion,
                automaticAcquisition: request.automaticAcquisition, phase: .committed, createdAt: stamp, updatedAt: stamp).insert(db)
            var migrationIDs: [UUID] = [], playlistIDs: [String] = []
            for (ordinal, plan) in plans.enumerated() {
                try Task.checkCancellation()
                let operation = preview.id + ":" + String(ordinal)
                let fingerprint = try PlaylistMigrationValidation.importFingerprint(for: plan.source)
                let session = try GRDBPlaylistMigrationRepository.insertCommittedPlaylist(db, source: plan.source, operation: operation,
                    fingerprint: fingerprint, displayName: plan.name)
                if let description = plan.description, let playlistID = session.destinationPlaylistID {
                    try db.execute(sql: "UPDATE playlists SET description = ? WHERE id = ?", arguments: [description, playlistID])
                }
                try PortableLibraryImportItemRecord(migrationID: session.id.uuidString, importID: importID, kind: plan.kind,
                    documentPlaylistID: plan.documentPlaylistID, contentFingerprint: plan.contentFingerprint, ordinal: ordinal).insert(db)
                for (entry, song) in zip(plan.source.entries, plan.songs) {
                    try PortableLibraryEntryRecord(entryID: entry.id.uuidString, migrationID: session.id.uuidString, importID: importID,
                        songRef: song.id, recordings: PortableLibraryEntryRecord.encode((song.recordings ?? []).map(\.videoId)),
                        resolution: .pending, updatedAt: stamp).insert(db)
                }
                migrationIDs.append(session.id)
                if let playlistID = session.destinationPlaylistID { playlistIDs.append(playlistID) }
            }
            return PortableImportCommit(importID: importID, migrationIDs: migrationIDs, playlistIDs: playlistIDs, reused: false)
        }
    }

    struct SourcePlan: Sendable {
        let source: PlaylistMigrationSourcePlaylist
        let songs: [PortableSong]
        let name: String
        let description: String?
        let kind: PortableImportItemKind
        let documentPlaylistID: String?
        let contentFingerprint: String
    }

    /// Document playlists become migration sessions (source `muzikBelesh`), preserving order
    /// and repeated occurrences exactly. Songs in no playlist go to a clearly labelled
    /// collection, split at the per-playlist limit.
    static func sources(_ preview: PortableImportPreview, request: PortableImportRequest) throws -> [SourcePlan] {
        let document = preview.document
        let songs = Dictionary(uniqueKeysWithValues: document.collection.songs.map { ($0.id, $0) })
        var plans: [SourcePlan] = []
        var names = Set<String>()
        for playlist in document.collection.playlists {
            guard let requested = request.playlists[playlist.id] else { continue }
            let name: String
            do { name = try LibraryIdentity.validatedName(requested) } catch { throw PortableLibraryError.invalidField("playlist name") }
            let ordered = try playlist.occurrences.map { occurrence -> PortableSong in
                guard let song = songs[occurrence.songRef] else { throw PortableLibraryError.invalidReference(occurrence.songRef) }
                return song
            }
            let option = preview.playlists.first { $0.id == playlist.id }
            plans.append(SourcePlan(source: try source(name: playlist.name, fingerprint: option?.fingerprint ?? PortableFingerprint.playlist(playlist, songs: songs), songs: ordered),
                                    songs: ordered, name: name, description: playlist.description, kind: .playlist,
                                    documentPlaylistID: playlist.id, contentFingerprint: option?.fingerprint ?? PortableFingerprint.playlist(playlist, songs: songs)))
            names.insert(LibraryIdentity.search(name))
        }
        if request.includeUnassigned {
            let referenced = Set(document.collection.playlists.flatMap { $0.occurrences.map(\.songRef) })
            let unassigned = document.collection.songs.filter { !referenced.contains($0.id) }
            let size = PortableLibraryLimits.occurrencesPerPlaylist
            for start in stride(from: 0, to: unassigned.count, by: size) {
                let chunk = Array(unassigned[start..<min(start + size, unassigned.count)])
                let base = start == 0 ? PortableImportNames.unassignedCollection : PortableImportNames.unassignedCollection + " " + String(start / size + 1)
                let name = names.contains(LibraryIdentity.search(base)) ? PortableImportNames.copyName(base, taken: names) : base
                names.insert(LibraryIdentity.search(name))
                let fingerprint = PortableFingerprint.playlist(chunk.map { PortableFingerprint.key($0) })
                plans.append(SourcePlan(source: try source(name: base, fingerprint: fingerprint, songs: chunk), songs: chunk, name: name,
                    description: "Songs from “\(preview.documentName)” that were not in any playlist.", kind: .standaloneSongs,
                    documentPlaylistID: nil, contentFingerprint: fingerprint))
            }
        }
        guard !plans.isEmpty else { throw PortableLibraryError.nothingSelected }
        return plans
    }

    private static func source(name: String, fingerprint: String, songs: [PortableSong]) throws -> PlaylistMigrationSourcePlaylist {
        let entries = songs.enumerated().map { index, song in
            PlaylistMigrationSourceTrack(position: index,
                title: song.title ?? song.recordings?.first.map { "YouTube video " + $0.videoId } ?? "Unknown song",
                primaryArtist: song.artist, additionalArtists: song.additionalArtists ?? [], album: song.album?.title,
                durationMs: song.durationMs)
        }
        let source = PlaylistMigrationSourcePlaylist(source: .muzikBelesh, name: name, sourcePlaylistID: fingerprint, sourceReference: nil, entries: entries)
        do { try PlaylistMigrationValidation.validate(source) } catch { throw PortableLibraryError.invalidField("playlist “\(name)”") }
        return source
    }
}

// MARK: - Progress

/// Real values only, each a distinct dimension, counted per unique imported song (a song in
/// several playlists counts once). Derived from durable state on every refresh.
struct PortableImportProgress: Equatable, Sendable {
    var songs = 0
    var available = 0
    var reusedLocally = 0
    var downloading = 0
    var verifying = 0
    var queued = 0
    var needsReview = 0
    var searching = 0
    var waiting = 0
    var failed = 0
    var skipped = 0
    var occurrences = 0
    var playlists = 0

    var fractionAvailable: Double { songs == 0 ? 0 : Double(available) / Double(songs) }
    var isSettled: Bool { downloading == 0 && verifying == 0 && queued == 0 && searching == 0 }
}

struct PortableImportActivity: Identifiable, Equatable, Sendable {
    let id: String
    let documentName: String
    let createdAt: Date
    let phase: PortableImportPhase
    let automaticAcquisition: Bool
    let migrationIDs: [UUID]
    let playlistIDs: [String]
    let progress: PortableImportProgress
}

extension PortableLibraryImportRepository {
    func activities(limit: Int = 20) async throws -> [PortableImportActivity] {
        try await db.read { db in
            try PortableLibraryImportRecord.order(Column("createdAt").desc, Column("id")).limit(limit).fetchAll(db).map { record in
                let items = try Row.fetchAll(db, sql: """
                    SELECT i.migrationID, m.destinationPlaylistID FROM portable_library_import_items i
                    JOIN playlist_migrations m ON m.id = i.migrationID WHERE i.importID = ? ORDER BY i.ordinal
                    """, arguments: [record.id])
                return PortableImportActivity(id: record.id, documentName: record.documentName, createdAt: record.createdAt, phase: record.phase,
                    automaticAcquisition: record.automaticAcquisition,
                    migrationIDs: items.compactMap { UUID(uuidString: $0["migrationID"]) },
                    playlistIDs: items.map { $0["destinationPlaylistID"] }, progress: try Self.progress(db, importID: record.id))
            }
        }
    }

    static func progress(_ db: Database, importID: String) throws -> PortableImportProgress {
        enum Rank: Int { case skipped, failed, waiting, review, searching, queued, downloading, verifying, available }
        var best: [String: Rank] = [:], reused = Set<String>()
        var result = PortableImportProgress()
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.songRef, p.resolution, e.status, e.localTrackID, a.state AS link, j.state AS job
            FROM portable_library_entries p
            JOIN migration_entries e ON e.id = p.entryID
            LEFT JOIN migration_acquisitions a ON a.entryID = e.id
            LEFT JOIN download_jobs j ON j.id = a.downloadJobID
            WHERE p.importID = ? AND e.removedAt IS NULL
            """, arguments: [importID])
        for row in rows {
            result.occurrences += 1
            let song: String = row["songRef"]
            let status = PlaylistMigrationEntryStatus(rawValue: row["status"]) ?? .pending
            let resolution = PortableEntryResolution(rawValue: row["resolution"]) ?? .pending
            let job = (row["job"] as String?).flatMap(StoredDownloadState.init(rawValue:))
            let link = (row["link"] as String?).flatMap(AcquisitionLinkState.init(rawValue:))
            let rank: Rank
            switch status {
            case .ready where (row["localTrackID"] as String?) != nil: rank = .available
            case .ready: rank = .waiting
            case .verifying: rank = .verifying
            case .downloading: rank = .downloading
            case .queued: rank = .queued
            case .matched:
                switch (link, job) {
                case (.associating?, _), (_, .verifying?), (_, .importing?): rank = .verifying
                case (_, .downloading?), (_, .resolving?): rank = .downloading
                case (.failed?, _), (.unsupported?, _), (_, .failed?): rank = .failed
                default: rank = .queued
                }
            case .matching: rank = .searching
            case .needsReview: rank = .review
            case .failed, .unavailable: rank = .failed
            case .skipped: rank = .skipped
            case .pending: rank = .waiting
            }
            if (best[song]?.rawValue ?? -1) < rank.rawValue { best[song] = rank }
            if rank == .available, [.provenance, .localMatch].contains(resolution) { reused.insert(song) }
        }
        result.songs = best.count
        result.reusedLocally = reused.count
        for rank in best.values {
            switch rank {
            case .available: result.available += 1
            case .verifying: result.verifying += 1
            case .downloading: result.downloading += 1
            case .queued: result.queued += 1
            case .searching: result.searching += 1
            case .review: result.needsReview += 1
            case .waiting: result.waiting += 1
            case .failed: result.failed += 1
            case .skipped: result.skipped += 1
            }
        }
        result.playlists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM portable_library_import_items WHERE importID = ?", arguments: [importID]) ?? 0
        return result
    }

    func setPhase(_ importID: String, _ phase: PortableImportPhase) async throws {
        let stamp = now()
        try await db.write { db in
            try db.execute(sql: "UPDATE portable_library_imports SET phase = ?, updatedAt = ? WHERE id = ?", arguments: [phase, stamp, importID])
        }
    }

    func unfinishedImports() async throws -> [PortableLibraryImportRecord] {
        try await db.read { db in
            try PortableLibraryImportRecord.filter(["committed", "reconciling"].contains(Column("phase"))).order(Column("createdAt")).fetchAll(db)
        }
    }
}
