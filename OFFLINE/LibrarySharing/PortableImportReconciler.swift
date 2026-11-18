import Foundation
import GRDB

/// Post-commit work for one confirmed `.mbelesh` import, resumable after relaunch.
///
/// Order (local first, never a second downloader):
/// 1. **Provenance** — a local track already downloaded from a YouTube video the document
///    references is reused after managed audio verification (exact recording identity).
/// 2. **Local metadata** — the established local matching index, scoring engine and decision
///    policy, committed through the ordinary matching leases. Only a `local` decision is
///    committed here; everything else is left untouched for ordinary matching.
/// 3. **Shared references** (automatic acquisition only) — the sender's recording is looked
///    up (paced, cached) and scored with the same engine. Only a `recommended` result is
///    accepted (the acquisition coordinator then downloads it once per video through the
///    DownloadManager and its Wi-Fi rules); anything else is saved as a pending candidate
///    for review. Thresholds are never relaxed.
/// 4. **Hand-off** — the rest belongs to the migration coordinator (discovery, review).
struct PortableImportReconciler: Sendable {
    let db: DatabaseQueue
    let migrations: GRDBPlaylistMigrationRepository
    let metadata: (any YouTubeMetadataProvider)?
    var pacer: MatchingRequestPacer = .shared
    var now: @Sendable () -> Date = { Date() }

    struct Report: Equatable, Sendable {
        var provenance = 0
        var localMatches = 0
        var references = 0
        var proposed = 0
        var deferred = 0
        /// Set when reference lookups stopped early (connectivity or provider limits).
        var lookupsInterrupted = false
    }

    private struct Pending: Sendable {
        let entry: PlaylistMigrationEntry
        let songRef: String
        let videos: [String]
    }

    @discardableResult
    func run(importID: String) async throws -> Report {
        guard let record = try await db.read({ try PortableLibraryImportRecord.fetchOne($0, key: importID) }),
              [.committed, .reconciling].contains(record.phase) else { return Report() }
        try await setPhase(importID, .reconciling)
        var report = Report()
        try await provenance(importID, report: &report)
        try Task.checkCancellation()
        try await localMatches(importID, report: &report)
        try Task.checkCancellation()
        if record.automaticAcquisition, metadata != nil { try await references(importID, report: &report) }
        try Task.checkCancellation()
        report.deferred = try await finish(importID)
        return report
    }

    // MARK: Steps

    private func pending(_ importID: String) async throws -> [Pending] {
        try await db.read { db in
            let rows = try PortableLibraryEntryRecord.filter(Column("importID") == importID && Column("resolution") == PortableEntryResolution.pending.rawValue).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.entryID, $0) })
            var result: [Pending] = []
            for migrationID in Set(rows.map(\.migrationID)).sorted() {
                for entry in try GRDBPlaylistMigrationRepository.entries(db, migrationID: migrationID) {
                    guard let row = byID[entry.id.uuidString] else { continue }
                    result.append(Pending(entry: entry, songRef: row.songRef, videos: row.videoIDs))
                }
            }
            return result
        }
    }

    private func provenance(_ importID: String, report: inout Report) async throws {
        let open = try await pending(importID).filter { !$0.videos.isEmpty && $0.entry.localTrackID == nil }
        guard !open.isEmpty else { return }
        let wanted = Set(open.flatMap(\.videos))
        let local: [String: String] = try await db.read { db in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.sourceIdentifier, s.trackID FROM track_sources s JOIN tracks t ON t.id = s.trackID
                WHERE s.sourceType = 'youtube' AND s.sourceIdentifier IS NOT NULL ORDER BY s.dateRecorded, s.id
                """) {
                let video: String = row["sourceIdentifier"]
                if wanted.contains(video), map[video] == nil { map[video] = row["trackID"] }
            }
            return map
        }
        // One verification per (track, video); every occurrence of every song using it.
        var groups: [String: (track: String, video: String, entries: [PlaylistMigrationEntry])] = [:]
        for item in open {
            guard let video = item.videos.first(where: { local[$0] != nil }), let track = local[video] else { continue }
            groups[track + "|" + video, default: (track: track, video: video, entries: [])].entries.append(item.entry)
        }
        for key in groups.keys.sorted() {
            try Task.checkCancellation()
            guard let group = groups[key] else { continue }
            let associated: [UUID]
            do { associated = try await migrations.associatePortableProvenance(trackID: group.track, videoID: group.video, entries: group.entries) }
            catch PlaylistMigrationStorageError.invalidLocalTrack { continue }
            try await resolve(associated, as: .provenance)
            report.provenance += associated.count
        }
    }

    private func localMatches(_ importID: String, report: inout Report) async throws {
        let open = try await pending(importID).filter { $0.entry.localTrackID == nil && $0.entry.status == .pending }
        guard !open.isEmpty else { return }
        let index = try await migrations.matchingLibrary()
        guard !index.recordings.isEmpty else { return }
        let scoring = CandidateScoringEngine(), policy = MatchDecisionPolicy()
        var decided: [UUID: [(PlaylistMigrationEntry, SongMatchDecision, MatchingLocalRecording)]] = [:]
        for item in open {
            let local = index.candidates(for: item.entry.source)
            let scores = local.values.map { scoring.score(source: item.entry.source, candidate: $0) }
            let decision = policy.decide(scores, truncated: local.truncated)
            guard decision.outcome == .local, let best = decision.ranked.first, let recording = index.recordings[best.recording.identity] else { continue }
            decided[item.entry.migrationID, default: []].append((item.entry, decision, recording))
        }
        for migrationID in decided.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let values = decided[migrationID] else { continue }
            let lease: MatchingSessionLease
            do { lease = try await migrations.beginMatching(migrationID: migrationID) } catch SongMatchingError.staleAttempt { continue }
            var matched: [UUID] = []
            do {
                for (entry, decision, recording) in values {
                    try Task.checkCancellation()
                    guard let claim = try await migrations.claimMatchingEntry(entry, session: lease) else { continue }
                    do {
                        try await migrations.commitMatching(claim, decision: decision, local: recording, librarySnapshot: index.snapshot)
                        matched.append(entry.id)
                    } catch PlaylistMigrationStorageError.invalidLocalTrack {
                        continue // Left for ordinary matching; never the runner-up.
                    } catch SongMatchingError.staleAttempt { continue }
                }
            } catch {
                try? await migrations.finishMatching(lease, paused: false)
                throw error
            }
            try await migrations.finishMatching(lease, paused: false)
            let ready = try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM migration_entries WHERE migrationID = ? AND status = 'ready' AND localTrackID IS NOT NULL",
                                    arguments: [migrationID.uuidString])
            }
            let confirmed = matched.filter { ready.contains($0.uuidString) }
            try await resolve(confirmed, as: .localMatch)
            report.localMatches += confirmed.count
        }
    }

    private func references(_ importID: String, report: inout Report) async throws {
        guard let metadata else { return }
        let open = try await pending(importID).filter { !$0.videos.isEmpty && $0.entry.localTrackID == nil }
        var videos: [String: YouTubeVideo] = [:], missing = Set<String>()
        for item in open {
            try Task.checkCancellation()
            var chosen: YouTubeVideo?
            for id in item.videos where !missing.contains(id) {
                if let cached = videos[id] { chosen = cached; break }
                do {
                    try await pacer.wait()
                    let video = try await metadata.metadata(videoID: id)
                    guard video.id == id else { missing.insert(id); continue }
                    videos[id] = video; chosen = video; break
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    let mapped = YouTubeError.map(error, fallback: .metadataUnavailable)
                    if MatchingDiscoveryFailurePolicy.immediate(mapped) || [.networkUnavailable, .requestTimeout, .rateLimited].contains(mapped) {
                        report.lookupsInterrupted = true
                        return // The rest is left to the coordinator, which waits for the network.
                    }
                    missing.insert(id)
                }
            }
            guard let video = chosen else { continue }
            if GRDBPlaylistMigrationRepository.portableReferenceRecommended(for: item.entry, video: video) {
                if try await migrations.acceptPortableReference(for: item.entry, video: video) != nil {
                    try await resolve([item.entry.id], as: .reference); report.references += 1
                }
            } else {
                try await migrations.proposePortableReference(for: item.entry, video: video)
                try await resolve([item.entry.id], as: .proposed); report.proposed += 1
            }
        }
    }

    private func finish(_ importID: String) async throws -> Int {
        let stamp = now()
        return try await db.write { db in
            try db.execute(sql: "UPDATE portable_library_entries SET resolution = 'deferred', updatedAt = ? WHERE importID = ? AND resolution = 'pending'",
                           arguments: [stamp, importID])
            let changed = db.changesCount
            try db.execute(sql: "UPDATE portable_library_imports SET phase = 'handedOff', updatedAt = ? WHERE id = ? AND phase = 'reconciling'",
                           arguments: [stamp, importID])
            return changed
        }
    }

    private func resolve(_ ids: [UUID], as resolution: PortableEntryResolution) async throws {
        guard !ids.isEmpty else { return }
        let stamp = now()
        try await db.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE portable_library_entries SET resolution = ?, updatedAt = ? WHERE entryID = ? AND resolution = 'pending'",
                               arguments: [resolution, stamp, id.uuidString])
            }
        }
    }

    private func setPhase(_ importID: String, _ phase: PortableImportPhase) async throws {
        let stamp = now()
        try await db.write { db in
            try db.execute(sql: "UPDATE portable_library_imports SET phase = ?, updatedAt = ? WHERE id = ? AND phase IN ('committed','reconciling')",
                           arguments: [phase, stamp, importID])
        }
    }
}
