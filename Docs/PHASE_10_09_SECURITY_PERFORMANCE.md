# Phase 10.9 final hardening — security, performance and cleanup

Final engineering pass before v1.1.0. Baseline: candidate build 98 from `3c18885`
(docs head `8111533`). Branch: `feature/phase-10-09-release`. No product features, no UI
redesign, no schema migration, no change to bundle identifiers, App Group or signing.
Spotify OAuth/Web API (canceled Phase 10.8) is not reintroduced.

Status markers: **PASS**, **FAIL**, **NOT RUN**. Nothing is reported as passing unless it
executed. Measurements on the CI simulator are labeled as such; none are iPhone numbers.

## Commits

| Commit | Kind | Change |
|---|---|---|
| `e0633e9` | Security (CI) | `prebuilt_run_id` passed through a validated env var, not interpolated into bash |
| `77e4cd8` | Security / reliability + tests | Bound untrusted audio metadata on import; balance security-scoped access; `ReleaseHardeningTests` |
| `a66de73` | Cleanup | Remove dead code and the unused Phase 1 mock layer |
| `d5551d5` | Performance | Playlist playback context built once per render instead of once per row |

Frozen source for verification and the IPA: **`d5551d5`**. Later commits change `Docs/` only.

## A. Code cleanup

### Removed dead code (212 lines, 13 files)

Each item was checked against production code, tests, Info.plist principal classes
(`ShareViewController` kept), `@main` (`OFFLINEApp` kept), SwiftUI navigation, Codable/GRDB
records (`StoredLikedTrack` kept: database record used by tests), the Share extension's
source list in `project.yml`, and workflow test selectors.

| Path | Removed | Reason |
|---|---|---|
| `OFFLINE/Mock/Models/MockModels.swift`, `OFFLINE/Mock/Stores/MockStores.swift` | Phase 1 fixture catalog and in-memory stores (`#if DEBUG`) | Only referenced by the DEBUG mock views below and by a test that tested the fixtures themselves |
| `OFFLINE/Features/Root/RootView.swift` | `TrackRow`, `TrackContextMenu`, `AlbumCard`, `PlaylistCard`, `ProgressRow` (`#if DEBUG`) | Never instantiated; "Demo Queue/Playlist" menus over mock data |
| `OFFLINE/App/AppContainer.swift` | DEBUG `music`/`playback` mock stores | Only used by the removed views |
| `Tests/Unit/Phase1StoreTests.swift` | 6 tests of the mock stores | Exercised fixtures, not product code; not named by any workflow selector |
| `OFFLINE/Feasibility/YouTube/YouTubeProbeViewModel.swift` | Unused view model | Diagnostics calls `container.youtubeProbe` directly |
| `OFFLINE/Features/Player/PlayerViews.swift` | `LegacySleepTimerSheet` (private) | Superseded by `SleepTimerSheet`; no references |
| `OFFLINE/DesignSystem/DesignSystem.swift` | `ErrorState` | No references |
| `OFFLINE/Audio/Phase4PlaybackModels.swift` | `ShuffleCycle` | Shuffle state lives in `PlaybackNavigationEngine`; no references |
| `OFFLINE/PlaylistMigration/Issues/MigrationIssueModels.swift` | `MigrationIssueSeverityLevel` | No references |
| `OFFLINE/PlaylistMigration/MigrationContracts.swift` | `PlaylistMigrationAcquiring`, `PlaylistMigrationCoordinating` | Phase 10.0 placeholder protocols never adopted; the real owners are `PlaylistAcquisitionCoordinator` / `PlaylistMigrationCoordinator` |
| `OFFLINE/PlaylistMigration/Coordination/PlaylistMigrationCoordinator.swift` | `reconcileMigration(_:)` | No callers (forwarded to `reconcileAll()`) |
| `OFFLINE/Storage/ImportExportService.swift` | `exportData(trackID:)`, private `stableID`, `normalized`, `normalizedOptional`, `import CryptoKit` | No callers; CryptoKit was only used by `stableID` |

All removed DEBUG code was already excluded from Release binaries; the removal changes no
Release behavior. `ArtworkView` stays (the artwork fallback uses it).

### Duplication, complexity, naming

- No consolidation was made. The candidates reviewed (YouTube URL validation shared by the
  app and extension through one source file; import parsers; download validation via
  `DownloadMedia`; SQL fragments in `MigrationIssueSchema`/`CoordinatorRepository`) are
  already single implementations reused by reference. Merging the separate background
  and foreground transfer delegates was rejected: their ownership and error semantics
  differ (background file must move synchronously on the delegate queue).
- No renames or file moves: persisted identifiers, migration IDs, accessibility identifiers
  and UI-test selectors depend on current names.

### Warnings

No local Swift toolchain was available for this pass (Windows host); compiler diagnostics
are taken from the CI builds (§E). No warning-suppression flags were added.

### Deferred refactoring opportunities (not done; behavior-sensitive or high risk)

| Area | Opportunity | Why deferred |
|---|---|---|
| `GRDBPlaylistMigrationRepository.swift` (1,152 lines), `PlaylistAcquisitionCoordinator.swift` (962) | Split by responsibility (persistence vs. recovery vs. read models) | Core migration state machine; no defect; needs its own phase with the full migration suites |
| `PlaylistDetailView` body | Extract ordinary/migration sections into subviews | UI-test selectors and edit-mode behavior; risk without interactive UI debugging |
| `AudioPlayerService` (667 lines) | Separate observer/route handling | Playback engine; accepted on device |
| Response bodies (`YouTubeURLSessionTransport`, `SearXNGURLSessionTransport`) | Stream with a byte cap instead of buffering then checking 8 MB / 4 MB | Hosts are allowlisted/user-configured and resource timeouts bound the read (§B residual) |
| GitHub Actions | Pin first-party actions to commit SHAs | Only `actions/checkout`, `upload-artifact`, `download-artifact` (v4) are used; tag pinning is an accepted residual |

## B. Security

### Threat model (actual trust boundaries)

| Input | Source | Controls in place |
|---|---|---|
| Playlist CSV/JSON/ZIP | User-selected Files document (possibly crafted) | Coordinated copy into a private `0700` staging dir, regular-file/symlink check, 20 MiB input cap; ZIP parsed in memory only (never extracted to disk) with independent central-directory preflight: no absolute/`..`/backslash/colon paths, no symlinks/special files, ≤128 members, ≤8 MiB/member, ≤32 MiB total, ≤200:1 ratio, CRC and size agreement, no nested archives, no ZIP64/encryption; JSON structure budget; 100 playlists / 20,000 occurrences / 10,000 per playlist; field and column limits; staging removed on every exit |
| Local audio files | User-selected document | Extension allowlist, AVFoundation validation, streaming copy, SHA-256 identity, embedded artwork decoded through ImageIO thumbnails with a 20 MiB cap; **metadata text now bounded (B1)** |
| YouTube search/metadata/artwork/media | Network | HTTPS only, no credentials/ports other than 443, host allowlist (`youtube.com`, `www.`, `m.`, `*.googlevideo.com`, YouTube image hosts), cookie-free ephemeral sessions, redirect classification (same purpose/method only, max 5, cookies/Authorization stripped), 15/25 s timeouts, 8 MB body cap; media: `*.googlevideo.com` only, redirects re-checked, 1 GiB cap, MIME/length/`ftyp`/decode verification before import |
| Invidious / SearXNG | Public registry / user-configured server | HTTPS (SearXNG HTTP only for explicit LAN hosts with a development switch), no redirects, no cookies, short timeouts, 4 MB cap; results reduced to 11-character YouTube IDs |
| Share extension | Other apps | ≤8 items, ≤4 KiB text, 8 s provider timeout, YouTube ID extraction only; coordinated, atomic App Group inbox with bounded queue |
| Database | App-internal | All values parameterized; the only interpolated SQL fragments are compile-time constants (`sqlOrder`, `reportCodes`, eligibility predicates, fixed table names) |
| Filesystem | App-internal paths from the database | `AppStoragePaths.relativeURL` rejects `..`/absolute paths and re-checks every resolved component stays under the root; deletions follow the Phase 10.9 deletion-site audit |
| CI/IPA | Workflow dispatch inputs | `contents: read` permissions, first-party actions only, build number regex-validated; **run ID now validated (B2)** |

### Confirmed findings

| ID | Severity | Location | Root cause | Exploitability / impact | Fix | Tests |
|---|---|---|---|---|---|---|
| B1 | Medium (reliability/input validation) | `StorageCoordinator.performImport` (`OFFLINE/Storage/ImportExportService.swift`), `LibraryRepository.resolveArtist/resolveAlbum` | Embedded tags and provider titles were passed to the library without the bounds metadata editing enforces. An artist/album over 300 characters threw `LibraryError.invalidMetadata`, failing the whole import of a playable file; titles were stored unbounded and could contain control characters | A crafted or unusual local file, or a YouTube video whose channel name exceeds 300 characters, could not be imported; unbounded titles inflate the database and search index. No data loss or escape | `AudioMetadata.sanitizedForLibrary(fallbackTitle:)`: control characters replaced, title trimmed and capped at 300 characters (inner spacing kept), artist/album normalized with `LibraryIdentity.display` and capped at 300; empty title falls back to the filename | `ReleaseHardeningTests.testMetadataSanitizerBoundsTextAndReplacesControlCharacters`, `…testOverlongProviderMetadataStillImportsWithBoundedText` (fails before the fix: import throws), `…testOrdinaryLocalImportKeepsFilenameTitleWithoutTags` |
| B2 | Low (CI) | `.github/workflows/ci.yml`, "Locate and verify compiled test products" | Free-text `workflow_dispatch` input `prebuilt_run_id` was expanded with `${{ }}` inside a bash script | Script injection by someone who can already dispatch workflows (write access); job token is read-only | Passed via `env` and required to match `^[1-9][0-9]*$` | `Scripts/check-test-hygiene.py` (static); exercised only when the input is used |
| B3 | Low (correctness) | `performImport` | `stopAccessingSecurityScopedResource()` was called even when `startAccessing…` returned false | Unbalanced release of a security-scoped grant held by another caller | Stop only when this call started access | Covered by the import suites (behavior otherwise identical) |

No Critical or High finding. No path traversal, archive escape, symlink escape, SQL
injection, arbitrary-endpoint request or credential exposure was found.

### Reviewed without change

- ZIP/CSV/JSON import, staging and cleanup (Phase 10.2/10.9 hardening already covers the
  checklist; `ReleaseCorruptImportTests` re-run).
- Share extension and `SharedLinkInbox` (stable, physically accepted; bounds above).
- Downloads: foreground and background transfers both validate the final response host,
  status, MIME, size and file content; staging files are removed for non-retained jobs.
- ATS: `NSAllowsArbitraryLoads = false`, `NSAllowsLocalNetworking = true` (SearXNG on LAN).
  No certificate pinning added.
- Debug code: UI-test hooks (`--ui-testing`, fixtures, `--reset-ui-library`) are all inside
  `#if DEBUG`; the reset is confined to a validated temporary root.
- Dependencies: ZIPFoundation 0.9.20 (exact), YouTubeKit 0.4.10 (exact), GRDB ≥ 7.11.1.
  No dependency was upgraded. No published advisory affecting these versions was
  identified in this pass; this was not verified against an advisory database from this
  host, so it is listed as residual.
- Secrets: none in the repository or workflows; unsigned builds, no signing material.

### Residual risks

- Network response bodies are buffered before the size check (bounded by allowlisted hosts
  and 25 s/20 s resource timeouts).
- Invidious instances from the public registry receive search queries (song titles) by
  design; documented in Phase 10.4.
- Music files use the default iOS data protection class (needed for background playback
  and transfers while locked).
- Actions pinned by major tag, not SHA.

## C. Performance

| Item | Baseline | Change | Measured difference |
|---|---|---|---|
| Ordinary playlist rows (`PlaylistDetailView`) | Every visible row evaluated `songs.map(\.id)`, i.e. `playlistTracks` (n dictionary lookups) plus an n-element array, per row: O(n) per row created while scrolling | Built once per body evaluation and shared by all rows | **Not measured.** The improvement is algorithmic (per-row O(n) → O(1)); no device or Instruments run was possible in this pass. Functional risk: none — same array, same rows |

Not changed, with reasons:

- Playlist import: Phase 10.9 stress results on the CI simulator (100 → 10,000 entries:
  15 ms → 830 ms stage+parse, 13 ms → 1,066 ms commit) show no bottleneck worth risk.
  The stress suites re-run in Stage B report the current numbers (§E).
- Library lookups (`tracksByID`, artist/album name maps) are already dictionary-indexed.
- Artwork: ImageIO thumbnailing, bounded in-memory caches (30 YouTube images, 180 s).
- Downloads: progress callbacks sampled at 0.5 s; one shared queue; bounded retries.
- Database: no query-plan change without evidence; no index added.

Measurement limitations: no Mac/Xcode on this host and no physical device access; CI
simulator timings are wall-clock observations, not iPhone, battery or thermal data.

## D. Maintainability

- Dead code: reduced (212 lines removed across 13 files; one obsolete test class).
- Duplication: unchanged (no genuine duplicates worth merging were found; see A).
- Complexity / coupling / state: unchanged except removing the DEBUG mock stores from
  `AppContainer` (two fewer DEBUG-only container properties).
- Warning count: not measured locally; see CI logs (§E). No suppression added.
- Input validation: import metadata now follows the same limits as editing.

No code-quality metric beyond the line/file counts above is claimed.

## E. Regression impact and verification

| Change | Affected features | Verification |
|---|---|---|
| B1/B3 import metadata | Local audio import, YouTube downloads (finalize → import), playlist acquisition | `ReleaseHardeningTests` (new), `Phase3ImportIntegrityTests`, `DuplicateDetectionTests`, `FullLocalLibraryIntegrationTests`, `DownloadTests`, `PlaylistAcquisitionTests`, `MigrationIssueRecoveryTests` |
| B2 CI | Diagnostic workflow only | Static hygiene check |
| Dead-code removal | None in Release (DEBUG-only and unreferenced code) | Full build + complete regression |
| Playlist row context | Ordinary playlist detail rows and playback context | `LibraryManagementUITests` / Library UI shard, `Phase4PlaybackTests`, `PlaylistSearchTests` |

Stage A (local, Windows host): `Scripts/check-test-hygiene.py` — 86 test classes,
3 workflows, 0 problems — **PASS**. `git diff --check` — **PASS**.

Stage B (`e9430c8`): **PASS**, 261 executed, 0 failed, including `ReleaseHardeningTests` 3/3.
Stage C (`e9430c8`): Library UI 16/16 and Compact 5/5 **PASS**; Units 594/595 and Other UI
18/24 **FAIL**, every failure one of the seven baseline failures from build 98 (T18 timing;
six migration/review UI tests). The first runs on `d5551d5` did not compile the test target
(fixed test-only in `e9430c8`). Details, run links and the build-99 IPA:
`Docs/PHASE_10_09_RELEASE.md` §16.

## Physical retest scope

Changed paths that reach the device: local audio import and the final import step of every
YouTube download (B1/B3), and ordinary playlist detail rows. Required device rows:
P10 (download queue), P15/P16 (tap a ready song, playlist search), P18 (Add Songs),
P22 (local audio import + offline playback, including a file with long tags if available).
P01–P08 acceptance is reused: the upgrade, import parser and persistence paths are
unchanged.
