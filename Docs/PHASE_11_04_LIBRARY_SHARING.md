# Phase 11.4: Portable music library export, import and sharing

Branch: `feature/phase-11-04-sharing`, from `develop` at `86f983e` (Phase 11.3 merged, #27).
Status: implemented; unsigned IPA built (run 44195714530); developer reports installed Phase 11.4 IPA and says the feature works. Detailed P01–P25 device checks **not individually verified**. Owner explicitly approves merging into `develop` with these limitations. **Not merged or released at time of documentation update.**

CI (run 44195714008, commit 8f5ac3e): static checks and the library shard pass; all 29 Phase 11.4 unit tests pass. The run is red only for failures that also fail on `develop` at 86f983e (ReleasePerformanceTests clock count, two ThemeServiceTests, ListeningAnalytics/PlaylistFileImport/PlaylistMigration/ReviewQueue UI tests) plus one simulator "Failed to terminate" flake in `LibraryManagementUITests.testAlbumNameAndArtistSurviveRelaunch` (passed on the previous run of identical app code).

Measured on CI (iOS 26.2 simulator, single run, not a guarantee): decode+validate of a 10,000-song / 1.55 MB document 0.71 s; preview+commit of a 10,000-occurrence playlist 2.93 s.

A user can export one playlist, several playlists or the whole library as a small `.mbelesh`
file, send it with AirDrop, Messages, Mail or Files, and import it on another iPhone running
Muzik Belesh. The file carries song metadata, playlist order and public YouTube recording
references only — **never audio, never personal data**. The receiving iPhone reuses songs it
already has, then finds and downloads the rest through the existing matching, acquisition and
download pipeline.

## 1. Architecture

| Piece | Location | Role |
| --- | --- | --- |
| `PortableLibraryDocument` and DTOs | `OFFLINE/LibrarySharing/PortableLibraryDocument.swift` | The explicit allowlisted format (schema version 1), limits, `UTType.muzikBeleshLibrary`, summary, content fingerprint |
| `PortableLibraryCodec`, `PortableLibraryValidator`, `PortableJSONPreflight` | `PortableLibraryValidation.swift` | Size → UTF-8 → byte-level preflight (depth, duplicate keys) → envelope (format, version, required features) → typed decode → field validation and NFC normalization |
| `PortableLibraryExporter`, `PreparedLibraryShare` | `PortableLibraryExporter.swift` | One read snapshot of the visible library order; DTOs built field by field; atomic file in private `exports/Export-<UUID>/` |
| `PortableLibraryFileReader`, `PortableLibraryImportPlanner` | `PortableLibraryImporter.swift` | Security-scoped, coordinated, bounded (32 MiB) read; preview with duplicates and local-availability estimates |
| `PortableLibraryImportRepository` | `PortableLibraryImporter.swift` | Single-transaction commit; idempotent per operation; progress queries |
| `PortableImportReconciler` | `PortableImportReconciler.swift` | Post-commit local-first reuse and strict reference acceptance; resumable |
| `PortableLibrarySchema` | `PortableLibrarySchema.swift` | Migration `v026_portable_library_sharing` and the three bookkeeping records |
| `LibrarySharingService` | `LibrarySharingService.swift` | `@MainActor` owner in `AppContainer`: export helpers, previews, imports, pause/resume/cancel, relaunch recovery, Open-in staging |
| Views | `OFFLINE/Features/Sharing/LibrarySharingViews.swift` | Music Sharing hub, export, import preview, progress cards |

No second downloader, player, matcher or coordinator exists. Each imported playlist is an
ordinary migration session with the new source `muzikBelesh` (never labelled Spotify), so
placeholders, review, manual matching, retry, issues, acquisition, Wi-Fi rules, playback and
removal all use the established Phase 10 code paths.

## 2. File format (`.mbelesh`, schema version 1)

UTF-8 JSON, sorted keys. UTI `com.th07.muzikbelesh.library` (conforms to `public.data`,
`public.content`), extension `mbelesh`, MIME `application/vnd.muzikbelesh.library+json`.

```json
{
  "format": "muzik-belesh-library",
  "schemaVersion": 1,
  "requiredFeatures": [],
  "exportId": "UUID",
  "createdAt": "ISO-8601",
  "generator": {"app": "Muzik Belesh", "version": "1.x"},
  "scope": "playlist | playlists | library",
  "collection": {
    "songs": [{"id": "s1", "title": "…", "artist": "…", "additionalArtists": ["…"],
               "album": {"title": "…", "artist": "…", "releaseYear": 2020, "position": 0},
               "durationMs": 200000,
               "recordings": [{"provider": "youtube", "videoId": "11-char-id"}]}],
    "playlists": [{"id": "p1", "name": "…", "description": "…",
                   "occurrences": [{"id": "o1", "position": 0, "songRef": "s1"}]}]
  }
}
```

**Identity layers (distinct):** `exportId` identifies the document instance (random, never
used for duplicates); `songs[].id`, `playlists[].id` and `occurrences[].id` are
document-scoped; `recordings` are public recording identities; the recipient's local track
IDs are never present. Occurrences may repeat a song; positions must equal order.

**Versioning:** a newer `schemaVersion` is refused with "exported by a newer version of Muzik
Belesh"; unknown `requiredFeatures` are refused; unknown optional fields and unknown recording
providers are ignored (never contacted).

**Limits:** 32 MiB input, 25,000 songs, 1,000 playlists, 10,000 occurrences per playlist (the
migration storage contract), 100,000 occurrences total, 5 recordings per song, 20 additional
artists, JSON depth 12, identifiers `[A-Za-z0-9._-]{1,64}`, title/artist/album 300,
playlist name 120, description 2,000 characters, duration ≤ 24 h.

## 3. Privacy contract (release blocker)

The exporter builds every DTO field by field from an allowlist; it never serializes a GRDB
record or table. **Never exported:** profile (username, picture, IDs, onboarding state),
listening analytics, sessions, history, playback position, queue, shuffle/repeat, sleep timers,
liked-song history, theme/accent, download/Wi-Fi/discovery settings, server URLs and
credentials, tokens, cookies, headers, signed or `googlevideo` URLs, local paths, filenames,
database/job/session IDs, diagnostics and device identifiers. YouTube references are
validated 11-character video IDs only.

`PortableLibraryExportTests.testPrivacyAllowlistExcludesEveryPrivateMarker` plants markers in
the profile, settings, track filenames, metadata sources and a signed `googlevideo` source
URL, then asserts none appear in the file and that every JSON key is in the allowlist.

## 4. Export

Entry points: Library header Music Sharing menu → **Export Library**; playlist actions →
**Export Playlist**; Profile → Music Sharing; Settings → Music Sharing.

The preview shows songs, playlists, playlist entries, songs with a recording reference, songs
the recipient will search for, songs in no playlist (library scope) and the file size, plus
"Not the audio files" and the never-included list. Visible order is reproduced exactly:
ordinary playlists use `playlist_tracks` then pending YouTube additions; migration playlists use
migration entries by source position (removed occurrences excluded), then manual occurrences,
then pending additions. **Share** opens the system share sheet (AirDrop, Messages, Mail, Files);
**Save to Files** opens the export picker. The file is written atomically into a private
directory that is removed when the share closes (and on next launch).

## 5. Import

Entry points: Library header Music Sharing menu → **Import Muzik Belesh Library**; Profile;
Settings; and opening a `.mbelesh` file from Files, Mail, Messages or AirDrop. An opened file
is copied into private staging at once and presented only after the profile gate, once no
other sheet is showing.

**Preview:** document metadata, songs already downloaded here (exact recording identity),
songs probably already present (title and artist), per-playlist selection, rename, expandable
song lists, and duplicate warnings:

- *Identical content* (canonical content fingerprint: ordered, repeat-aware song keys;
  independent of names, IDs and export ID) → skipped by default; turning it on imports a
  separate copy under a new name.
- *Same name, different content* → imported under "Name (2)".
- Nothing is ever overwritten or merged.

Songs that are in the sender's library but in no playlist are offered as **Include songs not
in any playlist**, imported into a clearly labelled "Imported Songs" playlist.

**Automatically find and download missing songs** (on by default) is the only acquisition
choice. Off: local songs are reused, nothing is searched or downloaded until the user starts
it (Find Missing Songs, or the playlist's own matching controls).

**Commit:** one GRDB write transaction creates every selected playlist, every occurrence
placeholder and the bookkeeping. A failure leaves the library unchanged. The preview's
operation ID plus a request fingerprint make a repeated confirmation return the original
result; the same operation with different choices is refused.

## 6. Reuse, matching and acquisition

`PortableImportReconciler` runs after the commit (and again after relaunch while the import
is `committed` or `reconciling`):

1. **Provenance:** a local track whose `track_sources` YouTube ID equals a referenced
   recording is reused after managed audio decoding and SHA-256 verification (one
   verification per track, every occurrence associated atomically). Evidence
   `portable-provenance`.
2. **Local metadata:** the existing local index, `CandidateScoringEngine` and
   `MatchDecisionPolicy`; only a `local` decision is committed, through the ordinary matching
   leases.
3. **Shared references** (automatic only): the referenced video's metadata is fetched (shared
   pacer, cached per video) and scored by the same engine. Only `recommended` (every strict
   gate, automatic confidence threshold) is accepted — the entry becomes `matched` and the
   acquisition coordinator downloads it once per video through `DownloadManager`, honouring
   Wi-Fi-only. Anything else is saved as a **pending** candidate for review. Thresholds are
   unchanged; connectivity or provider limits stop lookups and leave the rest to the
   coordinator.
4. **Hand-off:** remaining entries are marked `deferred`; with automatic acquisition each
   playlist goes to `PlaylistMigrationCoordinator.startMigration` (local, then discovery;
   discovered results still need review as before).

Placeholders, manual YouTube matching, local-file matching and review use the existing
playlist UI unchanged.

## 7. Progress, pause, resume, cancel

Progress is derived from durable state on every change (debounced region observation), per
unique imported song: available offline, reused from the library, downloading, verifying,
waiting to download, searching, needs review, not searched yet, couldn't be downloaded,
skipped. Pause/Resume/Stop delegate to the migration coordinator for every playlist of the
import (durable intent); a paused import is not resumed after relaunch. Stop keeps imported
playlists, verified songs and shared downloads.

## 8. Database (`v026_portable_library_sharing`)

See [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) and [MIGRATIONS.md](MIGRATIONS.md). Additive:
`playlist_migrations` is rebuilt (rows and rowids, constraints and index preserved) only to
widen its `source` CHECK; three new tables record imports, items and per-occurrence
resolution.

## 9. Tests

`Tests/Unit/LibrarySharing/`:

| Suite | Covers |
| --- | --- |
| `PortableLibraryFormatTests` | Round trip, versions, required features, unknown fields/providers, not UTF-8, malformed, oversize, nesting, duplicate keys (incl. escaped), references, positions, identifiers, control characters, fingerprint semantics, 10,000-occurrence document |
| `PortableLibraryExportTests` | Ordinary and migration order, repeats, placeholders, scopes, unassigned songs, provenance references, empty export, **privacy allowlist**, atomic share file, safe filenames |
| `PortableLibraryImportTests` | Order/repeats/source, idempotency and conflicts, identical/same-name duplicates, selective import and rename, unassigned collection, atomic failure, provenance reuse and progress, local policy parity, strict reference acceptance (never auto-accepting an unrelated video), relaunch recovery, 10,000-occurrence commit |
| `PortableLibrarySchemaTests` | v025 → v026 upgrade preserving rows, rowids, index, cascades and integrity; new source admitted, unknown refused |

Existing migration-count assertions were updated for v026. Performance tests print measured
durations (`PERF …` lines in the test log); no timing is claimed here that CI has not measured.

## 10. Physical acceptance checklist (developer)

Developer reported the installed IPA works, but did not provide individual P01–P25 results. All specific checks below remain **NOT INDIVIDUALLY VERIFIED**; do not mark any PASS without reported evidence.

| ID | Check |
| --- | --- |
| P01 | Upgrade from 11.3: library, playlists, downloads, profile, statistics and theme unchanged |
| P02 | Export one playlist from the playlist menu; preview numbers look right |
| P03 | Export selected playlists |
| P04 | Export the entire library; songs in no playlist counted |
| P05 | Share via AirDrop to a second iPhone |
| P06 | Save to Files, then open the file from Files |
| P07 | Open a `.mbelesh` from Messages/Mail while on another screen; import sheet appears after it |
| P08 | Open a file before creating a profile (fresh install): import appears only after onboarding |
| P09 | Import preview: playlist selection, rename, expandable song lists |
| P10 | Re-import an identical playlist: warned and skipped by default; copy works when turned on |
| P11 | Same name, different content: imported as "Name (2)", original untouched |
| P12 | Songs not in any playlist: "Imported Songs" created only when chosen |
| P13 | Songs already downloaded on the recipient are reused (available immediately, no download) |
| P14 | Automatic on: missing songs download through the Downloads queue, respecting Wi-Fi-only |
| P15 | Automatic off: nothing downloads until Find Missing Songs |
| P16 | Uncertain songs appear for review in the playlist; manual YouTube/local matching works |
| P17 | Progress card values change sensibly (available, downloading, verifying, review) |
| P18 | Pause, then Resume an import |
| P19 | Stop an import: playlists and downloaded songs kept |
| P20 | Force-quit during an import; relaunch continues (paused stays paused) |
| P21 | Double-tap Import: only one set of playlists |
| P22 | A damaged or non-Muzik-Belesh file shows a clear error and changes nothing |
| P23 | Exported file opened in a text editor shows no name, photo, settings, paths or URLs beyond video IDs |
| P24 | Theme accent is used throughout the sharing screens (try a non-lime accent) |
| P25 | Playback, Downloads, Search and Spotify/Exportify import still work |

## 11. Owner device feedback and integration decision — 2026-11-18

- **Developer feedback:** “i have the IPA downloaded” followed by “it works gng we good”. This confirms a positive general physical-device report, **not** execution or passage of every P01–P25 case. No specific song ordering, duplicate-import, privacy, second-device sharing, cross-device acquisition, recovery, or stress checks were individually reported.
- **Approval:** The project owner answered “yes merge” to the explicit question whether to merge with those remaining physical checks unverified. This is an explicit authorization to integrate Phase 11.4 into `develop` despite incomplete verification.
- **Build:** [unsigned IPA #107](https://github.com/T-h07/MuzikBelesh/actions/runs/44195714530) succeeded for application source `8f5ac3ea49479b2c66c5e5c8b60df0d97edfb3ce`; the later documentation-only branch head is separate.
- **CI:** [#294](https://github.com/T-h07/MuzikBelesh/actions/runs/44195714008) **FAILURE**, not green. Static checks and regression-library passed; regression-compact, regression-unit-accessibility and regression-other-ui failed, and aggregate build-and-test failed. The earlier implementation notes discuss pre-existing baseline failures and one flaky simulator test; this acceptance entry does **not** independently reclassify the current failure as harmless.
- **Decision:** Merge only into `develop` with the above documented waiver; keep `release`, `main`, tags, and published releases unchanged. This is an owner-approved integration decision, not a full test sign-off or claim of all requirements passing.
