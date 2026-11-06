# Phase 10.0 — Spotify Playlist Migration Foundation

Status: feature implementation; not a released or integrated Spotify importer.

## Boundaries

This foundation introduces immutable metadata snapshots, distinct per-occurrence identities,
a session and entry state machine, typed candidate/issue records, validation, deterministic
content fingerprints, progress summaries and provider protocols.

There are **no schema migrations, network requests, OAuth flows, automatic downloads, UI changes,
or runtime services** in Phase 10.0. The existing native player, Share extension, audio storage
and SQLite database retain their v1.0.0 behavior.

## Data contracts

- PlaylistMigrationSourcePlaylist contains playlist name, provider/source identity and an ordered array
  of PlaylistMigrationSourceTrack entries. Positions are contiguous and zero-based.
- PlaylistMigrationSourceTrack.id is an independent UUID for each **occurrence**. Duplicate
  Spotify track IDs are allowed and intentionally remain separate occurrences.
- PlaylistMigrationValidation.validate rejects unsafe names, oversized input, missing/duplicated
  positions and occurrence UUIDs, and malformed metadata.
- importFingerprint is stable across capture dates and regenerated occurrence UUIDs. It changes
  when material source data or ordering changes. It is not a licensing proof.
- PlaylistMigrationSession records intended destination identity and lifecycle state.
- PlaylistMigrationEntry relates an occurrence to an optional local StoredTrack ID; unresolved
  placeholders never require a fake StoredTrack.
- PlaylistMigrationProgress distinguishes committed metadata from locally ready audio.
- Candidate and issue models contain only persisted evidence and user-facing diagnostics.
  No access tokens or signed transient URLs should be saved in issue details.

## Follow-on phases

- Phase 10.1: GRDB tables, transactional playlist/placeholder creation, repository implementations,
  migration-aware read models and restart persistence. Enforce transitions at the storage boundary;
  validate local track availability before marking entry ready.
- Phase 10.2: Spotify JSON / Exportify CSV / ZIP import to the source snapshot contract.
- Phase 10.4: Source discovery and candidate scoring (not automatic rights to acquire audio).
- Phase 10.5: Authorized audio import through the existing DownloadManager/StorageCoordinator.
- Phase 10.6: Durable scheduling, retry, cancellation and lifecycle recovery.
- Phase 10.7: Issues and user review.
- Phase 10.8: Optional supported Spotify share/OAuth integration.

## Checks

Tests cover state-machine transitions, duplicate occurrences, 500-entry normalized snapshots,
validation of positions and metadata, deterministic fingerprints, Codable round-trips and distinct
metadata/audio progress semantics.

Phase 10.0 has no effect on released v1.0.0. CI must pass before merging into develop.
