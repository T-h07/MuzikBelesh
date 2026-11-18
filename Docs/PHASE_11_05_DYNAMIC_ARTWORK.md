# Phase 11.5: Dynamic collection artwork and automatic 2×2 mosaics

> **Current status (18 November 2026):** This feature is merged into the stable application and published in [Muzik Belesh v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0). Historical branch/CI/acceptance status statements below describe the original feature-implementation stage, not the current release state. The final release had 10/10 owner-reported expedited iPhone checks PASS; complete final CI was canceled with known risks accepted.


Branch: `feature/phase-11-05-artwork`, from `develop` at `03fabc8` (Phase 11.4 merged, #28). Target: v1.2.0.
Status: implemented; **not merged, not released**. Developer-reported physical-device acceptance **15/15 PASS** on 2026-11-18 using the user-facing P01–P15 checklist below. The distinct repository P01–P30 checklist has **not** been individually reported in full.

Playlists, albums, artists and the virtual Unassigned Songs collection show a 2×2 mosaic built
from up to four of their own local song covers. The mosaic changes every 30 minutes while the app
is in the foreground. A custom cover always takes priority. Nothing is fetched from the network,
and no music file, song metadata, order, membership, playback, download, analytics value or
`.mbelesh` export is changed.

## 1. Architecture

| Piece | Location | Role |
| --- | --- | --- |
| `CollectionArtworkIdentity`, `CollectionArtworkKind`, `CollectionArtworkMode` | `OFFLINE/Library/Artwork/CollectionArtwork.swift` | Stable identity (`playlist`, `album`, `artist`, `unassigned`) and the three per-collection modes |
| `CollectionArtworkSelector` | same | Pure, deterministic selection and precedence |
| `CollectionArtworkIndexBuilder` | same | One O(n) pass over a `LibrarySnapshot` to each collection's sorted, deduplicated candidate paths and custom path |
| `CollectionArtworkSchema`, `CollectionArtworkRepository` | `CollectionArtworkPreferences.swift` | Migration `v027_dynamic_collection_artwork`; per-collection mode rows |
| `UserDefaultsCollectionArtworkDefaults` | same | Global setting `artwork.automaticCollections.v1` (default on) |
| `CollectionArtworkService` | `CollectionArtworkService.swift` | `@MainActor` owner in `AppContainer`: index, preferences, the single rotation scheduler, foreground state |
| `MusicLibraryService.setCollectionCover` | `CollectionCoverService.swift` | Set/replace/remove a playlist or album custom cover through the existing managed-file journal |
| `ArtworkImagePipeline` | `OFFLINE/DesignSystem/ArtworkImagePipeline.swift` | The one shared, bounded decoded-image cache (replaces `ArtworkImageCache`) |
| Views | `OFFLINE/Features/Library/CollectionArtworkViews.swift` | `CollectionArtworkView`, canvas with crossfade, Appearance toggle, Artwork Settings sheet |
| UI fixtures | `OFFLINE/App/ArtworkFixtureSeeder.swift` | DEBUG `--artwork-fixtures` |

## 2. Precedence

1. Custom cover (playlist/album record `artworkRelativePath`, stored artist cover).
2. Automatic mosaic, when enabled for the collection and at least one usable song cover exists.
3. Legacy single cover (the first song cover), when mosaics are disabled.
4. Generic placeholder.

Enabling mosaics never replaces or deletes a custom cover. The settings sheet says:
"Your custom cover takes priority. Remove it to display the automatic mosaic."

## 3. Selection

- Candidates are a collection's own songs' managed artwork paths, deduplicated and sorted by
  path; unsafe, missing and corrupt paths are excluded.
- Playlists: ordinary memberships; migrated and `.mbelesh`-imported playlists use verified local
  recordings (`ready` entries' `localTrackID`) and manual occurrences. Remote artwork URLs are
  never used. Albums use persistent album identity, not similar names. Artists use performer
  and album-artist songs; only a stored artist cover counts as custom.
- Seed: FNV-1a of `kind:id`. Epoch: `floor(now / 1800 s)`, from an injectable clock, so a cold
  launch recomputes the same selection without restored state.
- More than four covers: windows of four through an affine permutation reseeded per cycle
  (SplitMix64), with a 6-epoch lookback so consecutive selections never repeat and every cover
  appears within 2n epochs.
- Exactly four: shown in sorted order, not reshuffled. One cover: top-left; two: diagonal;
  three: all but bottom-right. Empty cells use fixed neutral tiles; one cover never fills all
  four quadrants.
- Refresh Mosaic adds a per-collection offset (session only) and is enabled only with more than
  four candidates.

## 4. Rotation and invalidation

- One scheduler for the whole app sleeps until the next epoch boundary; nothing runs per row or
  per second. It is cancelled in the background (`scenePhase`) and the epoch is reconciled on
  return; returning within the same interval keeps the selection.
- The index is rebuilt off the main actor on library revision with a 250 ms debounce and
  published only when it changes, so a rename or a like re-renders nothing.
- Removed/replaced paths are invalidated in the image cache. Paths reported unusable while
  drawing are excluded until the next foreground return.

## 5. Rendering

- 250–350 ms (0.3 s) crossfade: the next composition is decoded first, then faded in over the
  fully opaque previous one. Reduce Motion switches without animation.
- Tiles are decoded by ImageIO at size buckets (128–1024 px), using the managed 256 px thumbnail
  for small tiles. One `NSCache` of 32 MiB, emptied on memory warning; simultaneous requests
  share one decode; cancellation is honoured; failures are remembered for 60 s.
- 1 pt gutter (0.5 pt below 120 pt), outer frame clipped with `AppRadius.medium`. Sizes: 60 pt
  rows, 220 pt playlist/album headers, 180 pt artist header and settings preview.

## 6. Settings

- Settings → Appearance → Collections → "Automatic Collection Artwork" (`appearance-automatic-artwork`).
  A save failure keeps the previous value and shows an error.
- Playlist and album menus → Artwork Settings: preview, Use App Default / Automatic Mosaic /
  Static Artwork, Refresh Mosaic, Change Cover, Remove Custom Cover (confirmed).
- Per-collection overrides win in both directions over the global setting and survive relaunch.
  Deleting a collection removes its row (triggers); a recreated collection starts at the default.

## 7. Accessibility

One element per artwork: "Automatic artwork for X" / "Custom artwork for X" / "Artwork for X",
with a value such as "4 song covers". List-row artwork is decorative (the row is already labelled).

## 8. Storage

`v027_dynamic_collection_artwork` creates `collection_artwork_preferences` only (see
[DATABASE_SCHEMA](DATABASE_SCHEMA.md), [MIGRATIONS](MIGRATIONS.md)). The table is not part of
`.mbelesh` export and is excluded from profile/library snapshot comparisons.

## 9. Tests

- Unit (`Tests/Unit/Artwork`): selection, precedence, preferences and migration upgrade from
  v026, candidate index (including migrated/imported playlists and a 10,000-song build), image
  pipeline, rotation scheduler, and integration with the real library service (custom cover
  set/replace/remove with reference-aware cleanup, invalidation, no mutation, playback isolation).
- UI (`Tests/UITests/CollectionArtworkUITests.swift`): mosaic, fallbacks, custom priority and
  removal, per-collection mode with relaunch, global setting with relaunch, non-default theme,
  scrolling 40+ mosaic rows.

## 10. Known limitations

- The Photos picker and the visual quality of crossfades are verified on device only.
- Refresh Mosaic offsets are not persisted; a relaunch returns to the clock's selection.
- Artist custom covers cannot be chosen in this phase (existing stored covers are honoured).

## 11. Physical device checklist (P01–P30)

The separate 30-condition repository checklist has not been individually completed or mapped to results. See the developer's 15-condition acceptance report below. Do not mark untested detailed conditions PASS.

## 12. Developer-reported physical-device acceptance — 2026-11-18

The developer confirmed an installed Phase 11.5 IPA and submitted the **user-facing 15-test checklist** with **15 PASS, 0 FAIL, 0 not tested**. These are developer observations, not independently repeated by CI or GitHub automation.

| User-facing ID | Reported check | Result |
| --- | --- | --- |
| P01 | Playlists display 2×2 artwork mosaics | PASS |
| P02 | Albums display 2×2 mosaics | PASS |
| P03 | Four distinct covers appear when available | PASS |
| P04 | Fewer than four covers use proper fallbacks | PASS |
| P05 | Artwork matches between Library and detail screens | PASS |
| P06 | Mosaics rotate after the configured interval (30 min) | PASS |
| P07 | Artwork transitions smoothly without flashing | PASS |
| P08 | Manual playlist/album covers take priority | PASS |
| P09 | Global automatic artwork toggle works | PASS |
| P10 | Per-collection artwork settings work | PASS |
| P11 | Artwork preferences survive app restart | PASS |
| P12 | Adding or removing songs updates artwork | PASS |
| P13 | Library scrolling remains smooth | PASS |
| P14 | Music playback stays uninterrupted | PASS |
| P15 | Existing playlists, downloads, themes and analytics still work | PASS |

**Important mapping:** The IDs above refer to the 15-item user-facing form and **do not correspond 1:1** to the repository's more detailed P01–P30 checklist. Any detailed check not directly covered remains unverified; do not infer full 30/30 acceptance.

### GitHub verification and merge readiness

- Feature source at acceptance: `ab12b093d1a714e85b9135ec5b33774da869bd64`, three commits ahead of `develop` at `03fabc800e89f7075edace9c43f564868a35f040`, zero behind.
- [Unsigned IPA run #108](https://github.com/T-h07/MuzikBelesh/actions/runs/44291800290) **SUCCESS** for feature source; `OFFLINE-unsigned-IPA` uploaded.
- [CI run #298](https://github.com/T-h07/MuzikBelesh/actions/runs/44290264115) was **in progress** when assessed. Static checks and regression-compact passed. Unit/accessibility failed in `ReleasePerformanceTests.testPlaybackClockDatabaseAndPublicationWork` (expected 12 / actual 15) and two `ThemeServiceTests`; regression-library failed when `LibraryManagementUITests.testUniversalLibraryGroupsFiltersAndSearchAfterRelaunch` exceeded its two-minute execution allowance. Regression-other-ui had not yet concluded. These are not artwork-specific test failures on the observed log, but full automated regression is **not green**; do not claim these failures are harmless or known baseline without controlled comparison.
- **Assessment:** Physical device acceptance PASS (all reported cases), branch structurally mergeable, **automated CI still a verification caveat**. Appropriate for owner-approved integration only if the owner explicitly accepts this CI risk; otherwise investigate/redress before merge. No merge authorization is implied by submitting the test results.
