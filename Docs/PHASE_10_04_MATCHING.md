# Phase 10.4 — Intelligent Song Matching

## Corrective update — 13 November 2026

The initial device build failed acceptance. This section supersedes the initial
background-cancellation and read-only imported-playlist behavior described below.
Do not label the corrective feature accepted until its native build and device
checks pass. CI and IPA execution remain assigned to the user; no workflows were
dispatched for this corrective update.

### Reproduced failure and isolation

The legacy MigrationPersistentText credential regex rejects ordinary title words
such as `Secret` or `Password`. `commitMatching` applied that diagnostics validator
to candidate titles and normalized source evidence. A valid sixth song after five
successful songs could therefore throw `unsafeDiagnostics`; the catch outside
the whole playlist then aborted all remaining work. The portable verification
script executes that actual regex literal and reproduces the predicate failure at
occurrence 6. MatchingCorrectionTests additionally exercises the real GRDB worker
path; it is prepared but NOT RUN on this Windows host. No device exception log was
provided, so this is a demonstrated abort path, not proof of the exact device event.

Matching now validates metadata using credential syntax, bearer values, URLs,
length and control characters rather than ordinary isolated words. The legacy
diagnostic validator remains unchanged. Unsafe candidate metadata still fails
its transaction; it is not persisted. A per-occurrence catch records the category
and legally marks an unchanged matching entry failed, then continues. Library
changes invalidate local uniqueness; the worker records reviewable failure and
rebuilds its index for subsequent songs. Concurrent skips/confirmations win over
stale worker results. A superseded session, database corruption, constraint
failure or inability to safely save a failure checkpoint stops the job; cleanup
errors are logged rather than hidden with `try?`.

OSLog category `PlaylistMatching` records category, session UUID, occurrence UUID,
stage, provider and a safe underlying error identifier. SQLite logs include result
and extended result codes, never SQL statements or arguments. Known Swift errors
use fixed descriptions/case names. Export contents, candidate titles, paths and
transport URLs are excluded. Per-entry issues and the dashboard show readable
failure categories. Rate limiting/offline/timeouts disable further requests to
that provider for the current run, while local work continues. Individual video
or metadata failures do not disable later entries.

### Durable recovery and background execution

v014 adds `migration_matching_jobs` (session FK, persisted user intent) and
`migration_matching_checkpoints` (occurrence FK, algorithm, retryable flag, outcome,
timestamp). Result, entry state and checkpoint commit in one transaction. Clean
review proposals are skipped on retry; local ready entries and explicit skips
remain untouched. Rejected candidates remain excluded. No-result, failed and
provider-interrupted work stays retryable without duplicating candidate rows.

AppContainer owns the view model and worker. A singleton background adapter
registers `com.th07.muzikbelesh.matching.*` once; iOS 26 requests use a unique suffix,
`BGContinuedProcessingTaskRequest` with `.fail` admission, and CPU/network work
only. Its handler starts the sole worker and reports actual processed/total
progress. Rejected admission falls back to `UIApplication.beginBackgroundTask`;
older supported iOS versions use that limited execution path directly. There is
no background GPU entitlement, silent audio or fake activity. Existing audio and
download background systems remain separate.

Switching applications, locking the screen or scene inactivity does not cancel.
Expiration cancels in-flight discovery, closes the owned lease where execution
time remains, and preserves resumable intent. Every completed occurrence is
already durable if iOS terminates before cleanup finishes. On the next foreground
or manual launch, a single restoration guard resumes saved running/systemPaused
intent. Force-quit does not schedule a new background launch. In-app Cancel saves
userCancelled intent and will not automatically resume. The OS exposes the same
expiration callback for system interruption and cancellation through its own task
UI; that distinction cannot be inferred reliably. In-app Cancel is the explicit
durable cancellation control. System suspension time is never reported as work.

The iOS behavior follows Apple's [continued processing guidance](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/)
and [identifier requirements](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:)).
Wildcard registration/admission, lock-screen behavior and SideStore provisioning
must be verified on the actual device. Fallback is limited runtime, not a promise
to finish a 1,000-entry job in the background. No deferred BGProcessing relaunch is
scheduled. The native build workflow is prepared for Xcode 26.2, with iOS 17 still
the deployment target and API availability guards around iOS 26 functionality.

### Candidate artwork and manual verification

SongRecording retains the original full video title separately from parsed
comparison metadata, plus actual channel and a validated thumbnail. Candidate
evidence stores only HTTPS YouTube image hosts with no credentials, query,
fragment or unexpected port. Inspection can derive the standard trusted thumbnail
from a validated 11-character video ID for older candidates. Invalid IDs cannot
produce an artwork request or Open on YouTube link. Rendering reuses YouTubeArtwork
and YouTubeArtworkLoader: lazy view tasks, cancellation, a 30-image/180-second
cache, bounded image data/downsampling, and fallback artwork. Matching itself does
not fetch thumbnails. Failed image requests never change matching state. Channel
is labelled uploader and never substituted for verified performer identity.

### Hybrid playlist schema, UI and playback

v014 also adds `playlist_local_occurrences`: UUID primary key, playlist FK with
CASCADE, existing track FK with CASCADE, independent nonnegative position,
creation time, UNIQUE(playlistID, position), and track index. Track IDs are not
unique: intentionally adding the same song twice creates separate occurrences.
Original migration entries, source positions, fingerprints, candidate ownership
and existing `playlist_tracks` semantics are unchanged. No synthetic Spotify
metadata is created. New occurrences append after all original source occurrences;
removal leaves ordering stable without renumbering source positions.

Imported playlists appear in Add to Playlist and expose Add Songs. The picker
explains duplicate/addition behavior. Manual rows have their own label and Remove
Added Song action. A 200-source playlist plus one manual occurrence shows 201 total
while its import dashboard still shows 200 source entries. Deleting a manual
occurrence never deletes the recording. Deleting a recording cascades only its
manual memberships; original occurrences retain their source metadata.

Resolve Existing Placeholder is a separate inspection action with confirmation.
It verifies managed audio decoding and SHA-256, checks the source snapshot for
concurrent changes, and commits user-confirmed candidate evidence and association
atomically. It creates no extra playlist occurrence. It does not weaken automatic
identity thresholds or permit automatic acceptance of an uncertain recording.

Hybrid playback supplies original playable occurrence IDs followed by namespaced
`local:<UUID>` IDs to the existing navigation/shuffle/repeat/remote-command engine.
Restoration and library refresh reconcile occurrence IDs, not only track IDs, so
removing one duplicate cannot leave a phantom occurrence. Unresolved source rows
are excluded. Candidate/status-only changes no longer trigger playback catalog
refresh; actual associations, memberships and track metadata still do. Decoder
validation and ordinary managed-audio availability checks remain in place.

### Corrective verification and delivery status

Executed locally: `python Scripts/verify-matching-corrections.py` — PASS for the
actual legacy regex failure predicate, revised credential syntax checks, actual
v013-to-v014 schema SQL, 200 preserved source rows, manual duplicates/removal,
foreign-key cascades, checkpoints and retained playback position. This is SQLite
and regex execution, not Swift/GRDB runtime execution. Changed Swift files passed
tree-sitter parsing; YAML/plist/source inclusion and Git whitespace checks passed.

Prepared XCTest suites: MatchingCorrectionTests (48/200 entries, recoverable
metadata/provider failure, concurrent skip/recovery, fatal persistence),
MatchingLifecycleTests (background/foreground, expiration, saved running intent,
explicit cancellation and pending OS admission), MatchingArtworkTests (URL/ID
safety, fallback, existing loader cache and network failure), and HybridPlaylistTests
(200 source rows, duplicate local occurrences, deletion, restart, queue identity,
v013 upgrade and explicit placeholder resolution). Existing schema-count assertions
now expect 14 migrations and legacy source-edit prohibitions remain enforced.
All corrective XCTest cases are NOT RUN here. Native compilation, actual OS
lifecycle behavior, final packaging, SideStore installation and device acceptance
are NOT RUN and remain the user's verification gates. Static parsing proves none
of those gates. The old failure result must not be changed to PASS based on this work.

The existing focused dispatch mode includes the corrective suites. No workflow is
started by these instructions. When building, choose a build number strictly above
the installed IPA; do not reuse the earlier build 75. For example, use 76 only if
75 is still the latest installed candidate. The bundle identifier, Share extension,
signing settings and prior migrations are retained. Install in place; do not delete
the app or its library. There is no merge or release in this update.

Implementation branch: `feature/phase-10-04-matching`, based on Phase 10.3 merge
`15ba93398bc0b8630dd6572b7a86c281c5f7e55a`. Physical-device acceptance of the initial implementation FAILED. The corrective
implementation below is pending native compilation and physical retest.

## Architecture and reused components

`PlaylistMigrationMatchingService` is an actor implementing the existing
`PlaylistMigrationMatching` read-only candidate contract plus a transactional batch
operation. AppContainer owns one `PlaylistMatchingViewModel`; navigation does not
own or cancel its job. The engine has no DownloadManager, audio resolver, playback
service, acquisition or track-creation dependency.

`LocalLibraryCandidateProvider` builds title and artist indexes once per run from
StoredTrack and its StoredArtist/StoredAlbum relationships. The provider-neutral
SongRecording feeds the pure CandidateScoringEngine and MatchDecisionPolicy.
ExternalCandidateDiscovery is injectable; YouTubeSearchProviderAdapter reuses the
app's YouTubeSearchService and cached YouTubeMetadataProvider. No additional
scraper, API key, Spotify API or account access is introduced.

## Identity and normalization

Comparison uses Unicode compatibility composition, POSIX case folding, apostrophe
normalization, punctuation/space folding, and removal of official audio/video
presentation labels. Raw candidate metadata remains separate from the immutable
source occurrence. `feat.`, `ft.` and `featuring` credits and multiple guest
separators are compared as sets. Joint primary credits remain whole rather than
guessing a primary performer. Diacritics are preserved. Unknown parenthetical
qualifiers are retained; meaningful words and version labels are never stripped.

Version traits are sets: studio/original mix, live, remix, instrumental, acoustic,
cover, karaoke, sped-up, slowed, nightcore, extended, radio edit, demo, remaster and
unknown. Title, album and optional provider description contribute indicators.
Combinations such as live acoustic and extended remix remain combinations.
Bare words in song names are not enough to establish a version declaration.

**Conservative limitation:** two unlabelled versions remain uncertain even with
identical titles, artist, album and duration. Missing labels do not establish
studio identity. Local automatic reuse currently requires compatible explicit
version traits. This intentionally reduces automatic completion for ordinary
Spotify imports. Remaster/original differences and different remix names require
review. Explicit local confirmation is available in the corrective update; Phase 10.4
never silently treats an unknown version as original.

## Scoring and decision policy

Scores are 0–100. The single deterministic scorer allocates title 35, primary
artist 30, featured credits 10, duration 10, version 10, and album 5 points.
Non-exact title scores combine token Jaccard similarity (60%) and normalized
Levenshtein similarity (40%), capped below equality. Comparison work is bounded
to 300 characters for edit distance. Exact normalized title identity remains a
mandatory automatic-selection gate; fuzzy scores only order review candidates.

SongMatchingConfiguration validates finite thresholds with
`0 <= review < high <= 100`. Defaults: high 90, review 65, top margin 12.
Duration defaults: strong <=2 seconds, supporting <=5 seconds, hard mismatch
above 10 seconds **or** 5% of the shorter recording. A 5–10 second discrepancy
requires review even if proportionally small. Missing/zero duration earns no
points and blocks automatic identity. Parameters are immutable, injectable and
tested; no settings UI is added. Existing accepted/rejected decisions are not
reclassified by later configuration changes.

Artist disagreement/unproven performer, featured-credit disagreement, non-exact
title, unknown/conflicting version, missing/severely different duration,
unavailability, near-equal competitors, candidate overflow, prior rejection and
stale ownership block automatic selection independently of score. A channel name
never establishes performer identity. Even high external scores remain pending
proposals with no local association or playable audio.

## Local-first discovery and verification

Each eligible source occurrence searches the shared local index before external
requests. Available managed files and pending deletion journals are checked when
building the index. A unique high-confidence local candidate bypasses external
discovery. Acceptance reuses the same decoder validation and SHA-256 verification
as `associateVerifiedTrack`; no audio file is copied or track inserted. Failed
verification leaves review evidence and does not try the runner-up.

Before local acceptance, a transaction checks the selected track, artist/album,
managed-file availability, deletion journal and complete catalog snapshot. A new
or edited competitor invalidates previously established uniqueness. Indexes are
reused for discovery; this additional catalog comparison deliberately costs an
O(library-size) read per automatic acceptance to avoid stale decisions. File
hashing occurs outside write transactions and away from the main actor. The
existing managed-file verification boundary still cannot make external filesystem
changes and SQLite writes one atomic operation; later playback/storage checks
remain necessary, as in Phase 10.1.

## Persistence, history and legal transitions

The corrective update adds v014; v001–v013 migration definitions and Phase 10.1
record meanings are unchanged. See the corrective schema and recovery section below. Candidate confidence remains 0–1 in
SQLite; inspection renders 0–100. Structured string evidence includes algorithm
version, source occurrence, provider identity, normalized titles, individual
signal scores, duration delta, source/candidate traits, gates, classification,
margin, explanation, evaluation date, rank and automatic/pending acceptance.
MigrationPersistentText validates all persisted values; raw responses, secrets,
transport diagnostics and transient URLs are not stored.

Session/entry leases use canonical SQLite timestamps and exact snapshots. A newer
session, changed/deleted entry, new candidate or changed user decision invalidates
an in-flight result. Local verification precedes one transaction that persists
the accepted evidence and ready association together. External/review/no-match
transactions likewise persist their evidence and entry state together. Failure
rolls back both. Candidates are upserted by occurrence + provider + provider track
ID; prior explicit decisions are preserved. Earlier pending evidence is retained
and labelled historical; currentAttempt/rank identify current recommendations.
At 60 retained candidates further discovery pauses for review; a run adds at most
40, bounding each newly managed history below 100 rows. Legacy records are not
deleted to enforce this bound. One reusable matching-attempt issue per occurrence
records failure/no-match diagnostics and resolves after a clean successful retry.

Eligible session states transition to matching. Eligible unresolved entry states
(pending, matching from an interrupted run, needsReview, unavailable, failed)
transition to matching, then ready, needsReview or unavailable via existing
validators. Skipped, already associated and accepted/queued/acquiring occurrences
are not reconsidered. Final session state is partiallyCompleted when any entry
is ready, otherwise awaitingReview. Cancellation/failure closes the lease to
paused and matching entries to needsReview. These states deliberately avoid
claiming total audio completion. A terminated process may leave matching state;
the next explicit start safely supersedes its lease. Source UUID, position,
metadata and playlist identity never change. Repeated recordings retain separate
candidate ownership and can reference one existing local track.

## Network and lifecycle bounds

One job and one request at a time. At most three injected providers; the production
configuration has YouTube only. YouTube uses at most two normalized queries and
no pagination, considers 30 videos per response, retains at most 20 distinct IDs,
and checks metadata for at most three likely results. Source version words are
preserved in queries; no live/remix variant is invented. Live/upcoming/unavailable,
malformed, shorts and obviously unrelated results are filtered. Search alone
does not establish availability. Metadata inspection never resolves a media stream.
Existing transport request/resource timeouts (15/25 seconds) and bounded search
cache are reused. Rate limiting/network failure disables that provider for the
rest of the run while local matching continues; earlier candidates and committed
local associations survive. No unbounded task group, retry loop or request queue.

The job publishes progress after every occurrence, checks cancellation between
entries/requests and before commit, and requests supported background continuation. Navigation is independent.
Backgrounding does not cancel the worker; expiration and user cancellation are separate. No continued execution while suspended/terminated is promised.
Explicit retry rebuilds the local index and reuses stable candidate identities.
Durable checkpoints skip clean completed review proposals; failed, interrupted and
no-result occurrences remain retryable. A changed explicit decision invalidates
its checkpoint.
Large runs hold source entries and the local catalog/index, not 1,000 provider
responses. Candidate inspection reads only its occurrence; dashboard summary
reads current recommendations after the run, not from every row render.

## UI and deferred functionality

The existing migration dashboard exposes Find Matching Recordings, counts,
progress, Cancel and errors. Source Entry inspection shows candidate provider,
score, classification, versions, evidence, gates and pending/accepted decisions.
The black/lime styling, source metadata, mini-player and queue remain intact.
There is no Download button. The corrective update adds explicit, atomically
verified local-placeholder resolution; full external-candidate review remains Phase 10.7.

Phase 10.5 authorized acquisition, Phase 10.6 durable scheduling and Phase 10.7
full review are not implemented. No releases, automatic merges or source-library
reset are part of this phase.

## Test inventory and verification

- SongMatchingPolicyTests: exact explicit identity, unlabelled uncertainty,
  different primary artist, every version conflict and combinations, correct
  remix, featured artists, Unicode/presentation suffixes, duration/missing duration,
  generic/missing/reordered words, near-equal competitors/overflow, external versus
  local outcomes, threshold validation, mandatory gates and determinism.
- MatchingDiscoveryTests: stable-ID deduplication, availability filters,
  channel-only uncertainty, bounded metadata/search, no pagination, partial
  provider failure, and version-preserving query generation.
- PlaylistMatchingIntegrationTests: real GRDB and synthetic managed WAV files;
  verified local reuse, A–B–A–C–A occurrence preservation, restart, file/hash failure,
  provider failure isolation, idempotency/rejection, stale session/entry/candidate
  ownership, catalog changes, unsafe-evidence rollback, cancellation, 0/1/500/1,000
  entries, and absence of new tracks/download jobs/queue entries/files.
- Existing PlaylistMigrationPersistenceTests remain unchanged and run alongside
  the new tests in the explicit `matching_only` mode of `playlist-migration.yml`.
  The existing workflow's default regression/UI checks are unchanged.

Verification handoff: the user owns further CI, IPA compilation and device
acceptance. No further remote verification is dispatched or monitored by this
implementation task. Implementation commits use `[skip ci]` to suppress the
repository's push-triggered full regression workflow.

| Check | Result |
| --- | --- |
| Tree-sitter Swift syntax parsing of all 11 changed/new Swift files | PASS |
| Project YAML, workflow YAML and recursive source/test inclusion | PASS |
| Git whitespace checks and unchanged database migration definitions | PASS |
| New matching XCTest suites on the final implementation | NOT RUN — handed to user |
| Final unsigned IPA compilation/packaging | NOT RUN — handed to user |
| Physical iPhone scenarios P0–P15 | NOT RUN |

Before that handoff, device packaging of initial implementation `800f27a` passed.
An earlier focused test-product build found a missing `await` in an integration
test's GRDB write; commit `27d41a1` fixes it. These earlier results do not establish
test or compilation success for the final revision. Static parsing is not Swift
type checking and device compilation is not functional acceptance.

## File manifest

Created:

- `OFFLINE/PlaylistMigration/Matching/SongMatchingPolicy.swift`
- `OFFLINE/PlaylistMigration/Matching/MatchingDiscovery.swift`
- `OFFLINE/PlaylistMigration/Matching/PlaylistMigrationMatchingService.swift`
- `OFFLINE/Features/Library/PlaylistMatchingViewModel.swift`
- `Tests/Unit/PlaylistMigration/SongMatchingPolicyTests.swift`
- `Tests/Unit/PlaylistMigration/MatchingDiscoveryTests.swift`
- `Tests/Unit/PlaylistMigration/PlaylistMatchingIntegrationTests.swift`
- `Docs/PHASE_10_04_MATCHING.md`

Modified:

- `OFFLINE/PlaylistMigration/GRDBPlaylistMigrationRepository.swift`
- `OFFLINE/App/AppContainer.swift`
- `OFFLINE/Features/Library/MigrationPlaylistViews.swift`
- `OFFLINE/Features/Root/RootView.swift`
- `.github/workflows/playlist-migration.yml` (optional focused dispatch mode only)

## Unsigned IPA and in-place update

Use the existing `build-ipa.yml`, this feature branch, and a build number above
the installed candidate. The previous successful Phase 10.3 IPA used build 74.
The initial Phase 10.4 candidate uses 75 (or a higher number for a correction).
The workflow builds Release for generic physical iOS/iphoneos with signing
disabled, retaining `com.th07.muzikbelesh` and its Share extension and including
the source SHA and package manifest. SideStore signs the artifact; install it
over the existing app with the same signing identity to retain compatible data.
Do not delete the installed app or recreate its library.

```sh
gh workflow run build-ipa.yml --ref feature/phase-10-04-matching -f build_number=76
gh workflow run playlist-migration.yml --ref feature/phase-10-04-matching -f matching_only=true
```

For any later build, replace 76 with a number above the most recently installed
version. Physical acceptance remains separate from build/test success.

## iPhone 13 Pro Max acceptance — all NOT RUN

| Scenario | Status |
| --- | --- |
| P0 In-place upgrade preserves songs, playlists, entries and downloads | NOT RUN |
| P1 Explicit compatible local identity reuses verified audio without copying | NOT RUN |
| P2 Reliable local identity sends no external requests | NOT RUN |
| P3 Same-title/different-artist collision stays unresolved | NOT RUN |
| P4 Version differences and unlabelled uncertainty remain reviewable | NOT RUN |
| P5 High-confidence external candidate is pending and not downloaded | NOT RUN |
| P6 Ambiguous external candidates require review | NOT RUN |
| P7 Candidate evidence and gates are inspectable | NOT RUN |
| P8 Source titles, artists, UUIDs and positions remain unchanged | NOT RUN |
| P9 Cancel preserves committed local matches | NOT RUN |
| P10 Network interruption preserves local results and retry | NOT RUN |
| P11 Restart preserves candidates, decisions and associations | NOT RUN |
| P12 500/1,000 entries: responsive scrolling and accurate progress | NOT RUN |
| P13 Repeated occurrences retain distinct positions/UUIDs | NOT RUN |
| P14 Playback, mini-player, lock screen, Bluetooth, shuffle and queue | NOT RUN |
| P15 No download jobs or newly playable external proposals | NOT RUN |

Record PASS, FAIL, BLOCKED or NOT RUN per scenario with device/iOS, commit SHA,
build number and observed evidence. Real-provider matching quality, accessibility,
device performance and SideStore upgrade acceptance require these manual checks.


## Corrective file manifest

Changes relative to `2f9c10d132eeb1f824abb2828a501a7520cea427`:

- `.github/workflows/build-ipa.yml`
- `.github/workflows/playlist-migration.yml`
- `Docs/PHASE_10_04_MATCHING.md`
- `OFFLINE/App/AppContainer.swift`
- `OFFLINE/Audio/AudioPlayerService.swift`
- `OFFLINE/Audio/PlaybackQueueManager.swift`
- `OFFLINE/Features/Library/DetailViews.swift`
- `OFFLINE/Features/Library/MigrationPlaylistViews.swift`
- `OFFLINE/Features/Library/PlaylistMatchingViewModel.swift`
- `OFFLINE/Features/Library/ResolveMigrationPlaceholderView.swift`
- `OFFLINE/Features/Root/RootView.swift`
- `OFFLINE/Library/HybridPlaylist.swift`
- `OFFLINE/Library/LibraryModels.swift`
- `OFFLINE/Library/LibraryRepository.swift`
- `OFFLINE/Library/MusicLibraryService.swift`
- `OFFLINE/PlaylistMigration/GRDBPlaylistMigrationRepository.swift`
- `OFFLINE/PlaylistMigration/HybridPlaylistSchema.swift`
- `OFFLINE/PlaylistMigration/Matching/MatchingBackgroundExecution.swift`
- `OFFLINE/PlaylistMigration/Matching/MatchingCandidateArtwork.swift`
- `OFFLINE/PlaylistMigration/Matching/MatchingDiscovery.swift`
- `OFFLINE/PlaylistMigration/Matching/MatchingRecovery.swift`
- `OFFLINE/PlaylistMigration/Matching/PlaylistMigrationMatchingService.swift`
- `OFFLINE/PlaylistMigration/Matching/SongMatchingPolicy.swift`
- `OFFLINE/Resources/Info.plist`
- `OFFLINE/Storage/DatabaseManager.swift`
- `Scripts/verify-matching-corrections.py`
- `Tests/Unit/Library/Phase4LibraryMigrationTests.swift`
- `Tests/Unit/Phase2StorageTests.swift`
- `Tests/Unit/PlaylistMigration/HybridPlaylistTests.swift`
- `Tests/Unit/PlaylistMigration/MatchingArtworkTests.swift`
- `Tests/Unit/PlaylistMigration/MatchingCorrectionTests.swift`
- `Tests/Unit/PlaylistMigration/MatchingDiscoveryTests.swift`
- `Tests/Unit/PlaylistMigration/MatchingLifecycleTests.swift`
- `Tests/Unit/PlaylistMigration/PlaylistImportIntegrationTests.swift`
- `Tests/Unit/PlaylistMigration/PlaylistMigrationPersistenceTests.swift`
- `project.yml`
