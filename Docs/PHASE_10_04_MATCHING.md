# Phase 10.4 — Intelligent Song Matching

Implementation branch: `feature/phase-10-04-matching`, based on Phase 10.3 merge
`15ba93398bc0b8630dd6572b7a86c281c5f7e55a`. Physical-device acceptance is pending.

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
review. Phase 10.7 can provide explicit identity confirmation; Phase 10.4 never
silently treats an unknown version as original.

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

No database migration is added: existing v001–v013 migration definitions and
Phase 10.1 record meanings are unchanged. Candidate confidence remains 0–1 in
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
entries/requests and before commit, and pauses on backgrounding. Navigation is
independent. No continued execution while suspended/terminated is promised.
Explicit retry rebuilds the local index and reuses stable candidate identities.
Large runs hold source entries and the local catalog/index, not 1,000 provider
responses. Candidate inspection reads only its occurrence; dashboard summary
reads current recommendations after the run, not from every row render.

## UI and deferred functionality

The existing migration dashboard exposes Find Matching Recordings, counts,
progress, Cancel and errors. Source Entry inspection shows candidate provider,
score, classification, versions, evidence, gates and pending/accepted decisions.
The black/lime styling, source metadata, mini-player and queue remain intact.
There is no Download button or confirmation action with incomplete persistence
semantics. Ambiguous candidates are clearly pending Phase 10.7 review.

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
gh workflow run build-ipa.yml --ref feature/phase-10-04-matching -f build_number=75
gh workflow run playlist-migration.yml --ref feature/phase-10-04-matching -f matching_only=true
```

For any later build, replace 75 with a number above the most recently installed
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
