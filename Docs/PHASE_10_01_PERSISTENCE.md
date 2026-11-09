# Phase 10.1 — Playlist persistence and occurrences

The file import layer that builds on this storage is documented in
[Phase 10.2 — Offline playlist metadata import](PHASE_10_02_IMPORT_ENGINE.md).

Phase 10.0 PR #13 merged as `3064868584b1e3ddd9ed2de7db7082e887986a81`.
Implementation uses the existing `feature/phase-10-01-persistence` branch. No
Spotify connectivity, source parsing, discovery, acquisition or scheduling is added.

## Schema

`v013_playlist_migration_storage` follows the unchanged v001–v012 sequence.

| Table | Ownership, constraints and indexes |
| --- | --- |
| `playlist_migrations` | UUID primary key; unique normalized operation ID; unique required destination playlist FK with CASCADE; provider, source playlist identity/name, Phase 10.0 fingerprint, expected count (0–10,000), status, timestamps and optional failure information. Status/creation index. |
| `migration_entries` | Globally unique occurrence UUID; migration FK with CASCADE; nonnegative source position; UNIQUE(migrationID, sourcePosition); UNIQUE(migrationID, id) for issue ownership; original title, artists (additional artists as JSON), album, duration, source identity/URI and safe artwork reference; optional track FK with SET NULL; state and timestamps. Migration/status and local-track indexes. |
| `migration_candidates` | Candidate UUID; occurrence FK with CASCADE; provider/recording identity, title/artist/duration, bounded confidence, JSON evidence, decision and timestamps. Entry/creation/identity index. |
| `migration_issues` | Issue UUID; migration FK with CASCADE; optional composite (migrationID, entryID) FK to prevent cross-session issue ownership; diagnostic fields, severity, resolution and timestamps. Migration/resolution and entry indexes. |

Enum CHECK constraints reject unknown states. Source track IDs are **not unique**.
The legacy `playlist_tracks` primary key and all earlier migrations are unchanged.
The same migration adds nullable `playback_state.migrationContextJSON` to retain
occurrence identities and the current occurrence through playback restoration.

## Creation and idempotency

`GRDBPlaylistMigrationRepository` implements `PlaylistMigrationPersisting` and
the additive `PlaylistMigrationStatePersisting` mutation contract. Snapshot and
operation validation happen before writing. Operation IDs are trimmed and Unicode
canonically composed; they are case-sensitive, 1–200 characters, without controls.

One GRDB write transaction checks operation identity, inserts the StoredPlaylist,
inserts the importingMetadata session, inserts **every** source occurrence, checks
exact contiguous positions/count/playlist ownership, and changes the session to
metadataReady. Only transaction commit exposes metadataReady and the complete set
to readers. An insertion/constraint/cancellation error before commit rolls back
all changes. After commit, retries return the durable session.

The Phase 10.0 fingerprint is unchanged (including its exclusion of occurrence
UUIDs, capture time and artwork). Same operation + same fingerprint returns the
existing verified session; different fingerprint returns `operationConflict`.
Separate operations are never merged by name or source recording/playlist ID.
Occurrence UUIDs are global identities: a new operation must supply fresh UUIDs;
reusing an already-owned occurrence UUID is an explicit constraint error, never
silent merging. The unique operation constraint and serialized database writes
protect concurrent connections.

## States, local audio and progress

Repository mutations enforce the Phase 10.0 transition matrices transactionally.
Only `associateVerifiedTrack` establishes ready: it requires an existing available
managed recording, safe supported path, readable regular file with recorded size,
successful audio validation and a matching stored SHA-256. It rechecks the track
and pending deletion journal before committing the association. Candidate acceptance
alone never establishes playability. Invalid transitions leave records unchanged.

Rendering and queue construction use availability, managed path, regular-file,
readability and nonzero recorded-size checks without whole-file hashing. AVFoundation
inspects audio again before playback. An externally modified same-size file requires
the existing storage integrity audit to detect changed bytes; ordinary rendering
does not rehash every recording. Filesystem changes after a check can still race
with selection; selection rejects missing/invalid files and retains placeholders.

`PlaylistMigrationProgress` is derived from persisted occurrences plus effective
local availability. Metadata completion means exact committed source representation.
Audio completion requires **all** occurrences ready and playable, including repeats;
skipped occurrences are unresolved under this policy. Empty committed playlists
are vacuously audio-complete. Completed lifecycle history is not rewritten after
audio deletion, but effective audio completion becomes false and the session is
included in incomplete-session results.

## Recovery and deletion

StorageCoordinator runs migration recovery after existing file-journal recovery and
missing-file reconciliation. Recovery verifies counts/order, clears invalid links,
and legally changes ready to unavailable. It preserves metadata, order, candidates,
issues and active lifecycle states without launching workers or network requests.
The playlist screen repeats this check on appearance/foreground activation.

- Track deletion changes ready occurrences to unavailable in a trigger; the FK
  sets localTrackID to NULL. Source rows, metadata and evidence survive.
- Track availability changes to missing/modified invalidate ready associations
  transactionally in a trigger.
- Destination playlist deletion cascades through its session, occurrences,
  candidates and issues. Other playlists, audio, likes and history are not owned
  by these records.
- Repository session deletion removes its destination and cascades owned metadata.
  Direct SQL session deletion leaves an empty ordinary destination playlist;
  callers should use the repository API. Neither path deletes local tracks/audio.
- Corrupt committed occurrence sets are reported explicitly; recovery never repairs
  them by silently dropping entries or creating an empty replacement session.

## UI and playback

LibrarySnapshot observes sessions and occurrences alongside the legacy library.
`MigrationPlaylistRow` carries original source metadata and an optional validated
local recording. SwiftUI identity is always the occurrence UUID. Counts include all
source occurrences; unresolved rows show title, artist, album, duration and status.
Play/Shuffle are disabled when no local occurrences are playable. Imported source
order is immutable in this phase; legacy add/remove/reorder operations reject these
destinations and the corresponding controls are hidden. Playlist rename, artwork
and deletion remain available. Ordinary playlist behavior is unchanged.

`MigrationPlaybackOccurrence` maps each occurrence UUID to a real track ID. Only
validated rows enter the playback context, in source order. The existing navigation
engine receives distinct occurrence identities for migration contexts, so repeated
local recordings survive sequential Next/Previous, shuffle, repeat and restoration.
The queue manager resolves identities to real local track IDs before selection;
placeholders never receive fabricated StoredTrack records. Navigation state and
the mapping are saved atomically with the existing playback snapshot/explicit queue.
Explicit Play Next/Add to Queue and ordinary context behavior remain supported.
Migration contexts also revalidate cached audio when resuming, restoring a paused
item or returning from an audio interruption, so a missing file cannot bypass the
selection checks merely because a player item already exists.

## Phase 10.2 contract and limits

The next phase supplies validated `PlaylistMigrationSourcePlaylist` snapshots with
distinct occurrence UUIDs, contiguous positions and an explicit stable operation ID.
Retrying an operation may regenerate UUIDs because fingerprints ignore them. New
operations use fresh occurrence UUIDs. Phase 10.2 must use repository creation rather
than writing playlist_tracks or fake tracks. Candidate and issue text must exclude
credentials and temporary URLs; the repository rejects recognizable credential
markers and query/fragment-bearing HTTP URLs. Artwork accepts public HTTPS references
without credentials/query/fragment and is not fetched in this phase.

No import entry point, file parser, match-review UI, download worker or account UI
is provided. Legal persisted in-progress states are retained; automatic worker
resumption belongs to later phases. Verification evidence is recorded below after
the actual Xcode runs, separately from known legacy simulator failures.

## Verification

`PlaylistMigrationPersistenceTests` uses real isolated on-disk GRDB databases for
v012 upgrades, v013 reopening, 0/1/10/500/1,000 entries, duplicate constraints,
injected mid-insert rollback, concurrent operation retries/conflicts, lifecycle
errors, evidence/issue restoration, file loss, deletion ownership and mixed playback.
`PlaylistMigrationUITests` covers 500 placeholders across relaunch and mixed rows.
The focused workflow also runs unchanged foundation and affected library/playback
regressions. Full repository gates remain separate and are not waived or weakened.

Focused verification on `e12db32` passed in
[run 42485666387](https://github.com/T-h07/MuzikBelesh/actions/runs/42485666387):

- Application and all test targets built with Xcode 26.2 / iOS 26.2.
- 14 unchanged portable foundation tests passed; the same tests also passed on iOS.
- 127 selected iOS unit/integration tests passed with zero failures, including all
  18 persistence tests and 95 existing affected storage/library/playback tests.
- Both migration UI tests passed, including 500 placeholders across relaunch.
- Integrity output reported 500/500 and 1,000/1,000 ordered, distinct occurrences,
  with zero playable audio. Rollback, eight concurrent connections, restart,
  A–B–A–C–A, mixed 500/10 playback and explicit-queue restoration tests passed.

The first [build attempt](https://github.com/T-h07/MuzikBelesh/actions/runs/42485060578)
compiled the application but failed the new test target due to a missing `try` in
one test. This was fixed before the successful focused run. No test was disabled
or weakened. Full PR checks are tracked in the pull request; a focused pass alone
does not establish that the complete legacy UI gate passed.
