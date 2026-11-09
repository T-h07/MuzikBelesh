# Phase 10.3 — Playlist import UI and migration monitoring

## Architecture and scope

Built from `origin/develop` at `69cb894` (merged Phase 10.2), on
`feature/phase-10-03-import-ui`. Reuses `PlaylistMetadataFileImporter`,
`PlaylistImportCoordinator`, the existing atomic GRDB creator, source occurrence
models, `PlaylistMigrationProgress`, and migration-aware playback. No parser,
normalization, database migration history, playback engine, signing, bundle ID,
Share extension, or provider integration changes.

Inspection found a view-owned task cancelled on disappearance, a modal sheet
that prevented navigation during work, no source-song preview/select-all controls,
no dashboard/entry inspector, unobserved migration issues, and repeated filtering,
sorting and filesystem availability checks from `migrationRows` during rendering.

This phase visualizes persisted state. It does not match, discover, acquire,
download, synchronize or schedule audio. A pending source entry is not an error.

## Review and selection

Library → Playlists → **Import Playlist** retains `import-spotify-playlist`.
Ordinary audio import remains separate. The existing Files picker accepts Spotify
account-data JSON, compatible Exportify CSV and ZIP archives containing those
formats. Each archive candidate retains its own source location and identity.

Review shows filename, format, detected/valid/invalid playlist counts, total known
occurrences (with an explicit unknown-count note), readiness, parser diagnostics,
duplicate classification, destination name and selection. Source-song expansion
uses direct List children with occurrence UUIDs, including repeated recordings.
Preview includes position (displayed one-based), title, primary/additional artists,
album, duration and source track ID. Source URLs are not rendered.

Select All selects new/changed validated candidates; Deselect All clears selection.
Invalid, ambiguous and existing candidates cannot be committed. Existing duplicates
link directly to their observed destination. Invalid destination names prevent
confirmation and show the existing validation message. Renaming changes only the
destination display name; source metadata/fingerprint remain unchanged.

Confirmation on the review screen shows selected playlists, source entries, new
destinations, existing duplicates, and invalid/excluded candidates. No additional
confirmation screen is introduced. Unknown counts are not represented as zero.

## Operation lifecycle and cancellation

`AppContainer.playlistImport` owns one shared `PlaylistImportViewModel`. The view
observes it rather than creating a task owner. Each load/commit has a UUID and one
stored task; busy guards prevent overlapping loads or commits. Completed, pending
and failed counts belong to the current commit operation. Preparation shows the
filename; commits show the current playlist. Parsing/staging and asynchronous
repository calls keep the established Phase 10.2 execution boundaries.

Close and swipe-to-dismiss remain available during work. Sheet dismissal informs
the model for memory cleanup, and never cancels the task. The user can switch tabs
or keep listening, then reopen Import Playlist. Explicit Cancel propagates task
cancellation to the existing parser/repository. Each committed transaction is
recorded even if cancellation arrives afterward. Subsequent cancellation or failure
does not remove earlier playlists. Failed candidates can be retried while review
is open; after closing, choosing the file again reconstructs review and detects
already committed destinations.

The task handle clears on completion. Successful all-eligible imports release the
parsed report immediately; other reviews release when the sheet closes, or when
an operation finishes after closure. Small result/session summaries and errors
remain available for reopening. A new file clears prior results before parsing,
so results are not misrepresented as a new import. No large source buffer is held
permanently by the shared coordinator. The existing importer still cleans private
staging on cancellation/failure/success.

The session is foreground/app-lifetime state, not a background worker. iOS may
suspend work when backgrounded. After termination, committed SQLite destinations,
occurrences, issues and dashboard state recover; transient reviews and uncommitted
candidates do not. No promise of execution after termination is made.

## Dashboard, progress and entry inspection

Each migration-managed playlist has a native expandable dashboard. Collapsed
content includes provider, session lifecycle, entry count, metadata count,
available-offline count and unresolved count. Expanded content includes original
name/provider/count, import date, lifecycle, pending/active, review-required and
failed/unavailable counts, all supported status categories, and persisted issues.
Issues show severity, resolution, affected source position and saved explanations.
An empty issue list says that no issues were recorded.

Metadata completion means the committed occurrence snapshot has its expected count
and contiguous source positions. Subsequent session failure/pause/cancellation does
not erase that metadata. Audio availability uses `MigrationPlaylistRow.effectiveStatus`
and repository availability checks. A 1,000-entry metadataReady playlist with no
associated audio displays 1,000/1,000 metadata, 0/1,000 offline and 1,000 unresolved.
These are determinate bars, never an ongoing download spinner. Empty sources omit
bars and percentages entirely.

Every source row retains its UUID and original position. Rows expose original
metadata, status, artwork/fallback and a separate Play button only for verified,
available audio. Tapping the row opens a source-entry inspector even for unresolved
entries. The inspector resolves its UUID against the current observed presentation
and updates status/issues without holding a stale row copy. Deleted sessions or
entries have explicit unavailable states. No placeholder is queued, reordered,
removed, represented as offline, or converted into a fabricated track.

## Observation and rendering

The existing `LibrarySnapshot` observation now reads `migration_issues` along with
sessions, entries and tracks. GRDB therefore invalidates on issue-only writes too.
`LibraryRepository.observedSnapshot` builds a presentation per destination, using
one availability check per distinct associated recording, grouped ordered entries,
status counters, and UUID/issue indexes. SQLite remains the only authoritative
store; these are disposable derived values, not a second database/cache.

GRDB performs fetch work on its database queue and delivers the snapshot using the
existing immediate/main-queue scheduler. The initial observation still delivers
synchronously as required by existing service consumers. SwiftUI callbacks remain
on the main actor. `migrationRows` and playlist counts now read an index instead
of scanning/sorting/stat-ing files during view rendering. Playback still re-reads
and validates through the existing migration playback mapping immediately before
starting. Missing files are reconciled on detail entry/foreground using awaited
utility work; normal track-availability writes also invalidate the observation.

Detail, review preview and expanded issue rows use List virtualization. Static row
content is Equatable, IDs are stable, and image tasks retain their existing stable
keys. The observation still reads the complete Library snapshot on relevant writes;
this phase does not introduce per-row observers or claim constant-time updates.
No polling, timers, simulated progress, hashes or audio decoding in row bodies.

## Artwork and accessibility

Verified playable recordings reuse `StoredArtworkView` / `ManagedArtworkView`,
including its background thumbnail decoding and bounded 32 MiB / 200-image cache.
Unresolved rows use a native music-list placeholder. Sanitized source artwork
references remain persisted but are not fetched. Remote images are optional and
intentionally unsupported in this interface, so importing and rendering work offline.

Uses semantic fonts, wrapping labels, text counts independent of color, native
navigation/List controls, descriptive statuses and 44-point primary controls.
Existing IDs are retained. New IDs include `migration-dashboard-toggle`,
`migration-overall-progress`, `migration-available-offline-count`,
`migration-unresolved-count`, `migration-entry-status-<UUID>`,
`playlist-import-operation-progress`, preview/selection/close/select-all actions,
issue IDs and inspector status. Playback controls and the existing mini-player,
remote commands, queue and restoration logic are unchanged.

## Automated coverage and verification evidence

Added `PlaylistImportPresentationTests` (six tests): review selection, invalid and
ambiguous candidates, destination naming/source identity, duplicate classification,
buffer cleanup, dismissal during confirmed import, prevention of a concurrent
commit, partial cancellation, and transaction failure/retry. The lifecycle tests
pause only the scheduling boundary; both transactions and observation use isolated
real GRDB databases. They prove the first playlist appears while the second is
still pending. No artificial ready flags or matching functionality are introduced.

Added `MigrationPresentationTests` (three tests): 0/1/500/1,000 logical occurrences,
repeated identities and order, restart, metadata/audio separation, issue isolation
and resolution, observed legal status transitions, associated valid managed WAV
audio through `associateVerifiedTrack`, missing files, persisted track availability,
and session deletion. Existing synthetic fixtures are reused.

Extended `PlaylistFileImportUITests` with multi-playlist selection/naming/preview,
invalid-source presentation, and a 1,000-entry dataset scroll/dashboard/inspection/
restart smoke test. The smoke test performs twelve rapid scrolls, checks distinct
visible UUIDs and entry inspection, and attaches elapsed time/screenshots when run.
It does not assert an arbitrary latency or claim every row is instantiated at once.
Existing Files-picker and 500-entry tests remain in place. Existing Phase 10.1/10.2
regression tests are not disabled or weakened. XcodeGen already includes these
source/test directories; normal push-triggered full CI includes the new suites.

Executed locally on Windows: tree-sitter Swift syntax parsing of all 13 changed/new
Swift files; project YAML/source-inclusion checks; Git whitespace and scope checks.
These checks are not Swift type checking, an application build, XCTest, UI rendering,
or measured device performance. No Swift compiler, Xcode, iOS SDK or simulator is
available on this host. All added XCTest/UI tests are **NOT RUN in this session**.
No workflow was dispatched, monitored or rerun; no PR or release was created.

## Physical-device acceptance — all NOT RUN

Primary device: iPhone 13 Pro Max, iOS 17+. Record device/OS, build SHA, elapsed time
and any memory-pressure observations when performing these checks.

- [ ] Files picker open/cancel; JSON/CSV/multiple-member ZIP; malformed diagnostics.
- [ ] Candidate names/formats/counts, source preview including repeated recordings,
      independent selection, Select All/Deselect All, destination rename.
- [ ] Existing duplicate opens its destination; ambiguous/invalid input cannot commit.
- [ ] 0/1/500/1,000 entries, exact original order and distinct occurrence identities;
      retain compatibility with the existing 10,000-entry engine limit.
- [ ] Rapid scrolling, dashboard expand/collapse, largest Dynamic Type and VoiceOver;
      verify wrapping, touch targets, contrast and accessible progress descriptions.
- [ ] Close during parsing/commit; navigate Home/Search/Library/Downloads; reopen;
      verify per-transaction Library arrival and Cancel after partial success.
- [ ] Observe legal pending/review/failed/skipped/ready/unavailable transitions and
      issue insert/resolve while navigating and while entry inspection is open.
- [ ] Associate real verified managed audio through the repository; confirm local
      artwork, correct Play enablement and unchanged source order/metadata.
- [ ] Missing local audio and empty issue lists; deleted destination/session.
- [ ] Airplane Mode import, missing artwork fallback and no provider image requests.
- [ ] Background/foreground, application restart, interrupted uncommitted import;
      committed data/dashboard restore without simulated worker resumption.
- [ ] Existing playback continues throughout: background/lock-screen/AirPods/Bluetooth,
      shuffle/repeat, queue persistence/restoration, mini-player, ordinary playlists.
- [ ] Ordinary device memory pressure with a large review/detail; verify resource use
      and record actual measurements. No smoothness/memory acceptance is claimed yet.

Known verification limits: native compile/type-check and simulator/device execution
remain outstanding. The previously reported Files-picker Cancel assertion and legacy
simulator timeout were not investigated because they do not block implementation.
iCloud Drive-provider acceptance remains excluded as in Phase 10.2.

## File manifest

Modified: `OFFLINE/App/AppContainer.swift`,
`OFFLINE/Features/Library/LibraryView.swift`, `PlaylistImportView.swift`,
`MigrationPlaylistViews.swift`, `DetailViews.swift` (the latter three in the same
Library feature directory), `OFFLINE/Library/LibraryModels.swift`,
`OFFLINE/Library/LibraryRepository.swift`, `OFFLINE/Library/MusicLibraryService.swift`,
`OFFLINE/PlaylistMigration/MigrationReadModels.swift`,
`Tests/UITests/PlaylistFileImportUITests.swift`.

Created: `OFFLINE/Features/Library/PlaylistImportViewModel.swift`,
`Tests/Unit/PlaylistMigration/PlaylistImportPresentationTests.swift`,
`Tests/Unit/PlaylistMigration/MigrationPresentationTests.swift`, and this document.
