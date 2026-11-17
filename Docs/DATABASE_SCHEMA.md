# Phase 2 database schema

Muzik Belesh uses GRDB 7.11.1 with a `DatabaseQueue` stored privately at `Library/Application Support/MuzikBelesh/muzikbelesh.sqlite`. Foreign keys are enabled before migrations run. All timestamps are absolute `Date` values and all user-owned identifiers are stable UUID strings.

Migrations are registered in `OFFLINE/Storage/DatabaseManager.swift`:

1. `v001_initial_library` — artists, albums, tracks, and track indexes.
2. `v002_playlists_and_likes` — playlists, ordered membership, liked tracks.
3. `v003_playback_and_history` — playback singleton, queue entries, history.
4. `v004_download_jobs` — future download-job records only.
5. `v005_settings_sources_imports` — typed settings rows, source records, and import-operation recovery records.
6. `v006_phase4_playback_state` — context, shuffle cursor, timer deadline and queue origin.
7. `v007_sleep_timer_duration` — selected timer duration.
8. `v008_navigation_history` — played IDs and history cursor.

Tracks reference optional artists and albums. Playlist membership, likes, queue entries, history, sources, and jobs reference tracks. Deleting a playlist never deletes tracks; deleting a track cascades dependent relationship records. The unique `tracks_contentSHA256` index provides content duplicate detection, while source records remain extensible for later YouTube integration.

## Phase 7 downloads

v009 and v010 add library management and managed albums. v011 extends download_jobs with title, channel, thumbnail, position, received and expected bytes, attempt count, and start and finish dates. A partial unique index covers YouTube IDs for managed jobs. Legacy rows retain their original fields.

## Phase 10.1 migration playlists

`v012_background_transfers` extends download transfer ownership.
`v013_playlist_migration_storage` adds `playlist_migrations`, `migration_entries`,
`migration_candidates`, and `migration_issues`, plus nullable playback occurrence
context. Session destinations and operation identities are unique; occurrence IDs
and (migrationID, sourcePosition) are unique; provider track IDs are not. Track
links use SET NULL and migration ownership uses CASCADE. See
[Phase 10.1](PHASE_10_01_PERSISTENCE.md) for constraints, indexes and deletion triggers.

## Phase 11.1 local profile

`v024_local_user_profile` (appended after v022; `v023` stays reserved for the canceled
Phase 10.8 build) adds `local_user_profile`: `slot INTEGER PRIMARY KEY CHECK(slot = 1)`,
`id TEXT UNIQUE`, `username`, nullable `avatarRelativePath` (a bare file name, no `/`),
`createdAt`, `updatedAt`. The `slot` key allows exactly one row. No table references it
and it references none. See [Phase 11.1](PHASE_11_01_LOCAL_PROFILE.md).

## Phase 11.2 listening analytics

`v025_listening_analytics` (appended after v024) adds three tables. `listening_sessions` holds
one row per playback that actually produced audio: `trackID` (`REFERENCES tracks ON DELETE SET
NULL`), `startedAt`, `startDay` (local `yyyy-MM-dd`), `lastCheckpointAt`, `endedAt`,
`listenedMs`, `durationMs`, `contextKind`, `contextSourceID`, `qualified`, `completed`,
`state` (`active`, `finished`, `recovered`) and `endReason`. `listening_session_days`
(`sessionID` cascade, `day`, `listenedMs`, primary key `(sessionID, day)`) splits each
session's time across local calendar days. `listening_analytics_state` is a single row with
`trackingStartedAt`. Indexes cover `startDay`, `trackID`, `(contextKind, contextSourceID)`,
active sessions and `(day, sessionID, listenedMs)`. `playback_history` is unchanged and is
not used for listening time. See [Phase 11.2](PHASE_11_02_LISTENING_ANALYTICS.md).

## Phase 11.4 library sharing

`v026_portable_library_sharing` (appended after v025) rebuilds `playlist_migrations` with the
same columns, rows (including rowids), primary key, UNIQUE constraints and
`playlist_migrations_status` index, widening only the `source` CHECK to admit `muzikBelesh`.
Child tables keep their `REFERENCES playlist_migrations(id)` clauses. It adds:

- `portable_library_imports`: `id`, `operationID` (unique), `requestFingerprint`, `exportID`,
  `documentName`, `schemaVersion`, `automaticAcquisition`, `phase`
  (`committed`, `reconciling`, `handedOff`, `cancelled`), `createdAt`, `updatedAt`.
- `portable_library_import_items`: `migrationID` (primary key, cascade from
  `playlist_migrations`), `importID` (cascade), `kind` (`playlist`, `standaloneSongs`),
  `documentPlaylistID`, `contentFingerprint` (indexed, duplicate detection), `ordinal`
  (unique per import).
- `portable_library_entries`: `entryID` (primary key, cascade from `migration_entries`),
  `migrationID`, `importID` (cascades), `songRef`, `recordings` (JSON array of validated
  YouTube IDs, ≤ 200 characters), `resolution` (`pending`, `provenance`, `localMatch`,
  `reference`, `proposed`, `deferred`), `updatedAt`.

No profile, listening, preference or device data is referenced. See
[Phase 11.4](PHASE_11_04_LIBRARY_SHARING.md).
