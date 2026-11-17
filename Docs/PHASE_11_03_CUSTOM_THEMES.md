# Phase 11.3: Custom themes, accent colours and the reactive appearance system

Branch: `feature/phase-11-03-themes`, from `develop` at `f1d4e78` (Phase 11.2 merged).
Status: implemented; **10/10 developer-reported physical-device checks PASS** on 2026-11-17. Native CI not green (canceled regression shards); not merged, not released.

## 1. Architecture

| Piece | Location | Role |
| --- | --- | --- |
| `ThemeRGB` | `OFFLINE/DesignSystem/Theme.swift` | Opaque 24-bit sRGB value; strict `#RRGGBB` parser; WCAG luminance/contrast |
| `ThemePreset`, `ThemeSelection` | `Theme.swift` | Eight stable preset ids plus `.custom` |
| `ThemePalette` | `Theme.swift` | Derived semantic tokens; `Equatable`; placed in the environment as `\.themePalette` |
| `ThemeService` | `OFFLINE/DesignSystem/ThemeService.swift` | `@MainActor ObservableObject`, the single source of truth, owned by `AppContainer` |
| `ThemePreferenceStoring` | `ThemeService.swift` | Injectable storage; `UserDefaultsThemePreferences` in the app, in-memory or an isolated suite in tests |
| `ThemeRoot` | `ThemeService.swift` | Observes only `ThemeService`; applies `.environment(\.themePalette)`, `.environmentObject(theme)` and the root `.tint` |
| `AppearanceSettingsView` | `OFFLINE/Features/Settings/AppearanceSettingsView.swift` | Preview, preset grid, custom colour, reset |

`ThemeRoot` wraps the whole interface inside `KeyboardSafeHost`, so tabs, navigation stacks,
sheets and full-screen covers inherit the palette. Views read
`@Environment(\.themePalette) private var palette`; only views that read it re-render on a
change. There is no mutable global, no `.id(theme)` rebuild and no root view replacement, so
navigation paths, selected tab, presented sheets and scroll positions are kept.

A theme change does not touch the database, `AudioPlayerService`, `MusicLibraryService`,
`DownloadManager` or `ListeningStatsService`. Statistics are not recomputed: the dashboard
re-renders cached summaries with new colours.

## 2. Presets

| Name | sRGB | Contrast on black | Foreground on accent |
| --- | --- | --- | --- |
| Original Lime (default) | `#D6EEA3` | 16.6:1 | black |
| Purple | `#B69CFB` | 9.1:1 | black |
| Violet | `#9670F7` | 6.0:1 | black |
| Blue | `#60A5FA` | 8.3:1 | black |
| Cyan | `#22D3EE` | 11.6:1 | black |
| Pink | `#F472B6` | 7.9:1 | black |
| Red | `#FB7185` | 7.8:1 | black |
| Orange | `#FB923C` | 9.3:1 | black |

Every preset meets WCAG AA (4.5:1) against the black background and is shown exactly as
defined. Ids (`lime`, `purple`, …, `custom`) are persisted and never change.

## 3. Persistence

- One `UserDefaults` key, `appearance.theme.v1`, holding JSON
  `{"version":1,"selection":"purple","custom":"#B69CFB"}`. No GRDB migration.
- Read synchronously as the first statement of `AppContainer.init`, before any view exists:
  no Lime flash on launch.
- Restore falls back field by field: corrupt JSON or an unknown version → Original Lime; an
  unknown preset id → Original Lime (a valid custom colour is kept); `custom` with a malformed
  hex → Original Lime. Restoring never rewrites the stored value.
- Custom colour drags apply live; writes are coalesced (400 ms) and flushed when Appearance
  disappears or the scene leaves `.active`.
- A failed write keeps the applied theme for the session and shows a non-blocking message.
- "Restore Original Theme" selects Lime and keeps the saved custom colour for later.
- UI tests use `UserDefaults(suiteName: "ThemeUITests-<MB_UI_TEST_ID>")`, wiped by
  `--reset-ui-library`; `--theme-preset <id>` seeds a selection.

## 4. Tokens and contrast

`ThemePalette` exposes `accent`, `onAccent`, `accentMuted`, `accentSubtleBackground`,
`accentBorder`, `accentSelection`, `chartPrimary`, `chartSecondary` and `controlTint`.
Backgrounds, text and status colours (`AppColors.success/warning/error/destructive`) are fixed.

- `onAccent` is black or white, whichever contrasts more with the displayed accent.
- A custom colour below 4.5:1 on black (for example `#101020`) is **displayed** mixed toward
  white in 5 % steps until it reaches 4.5:1. The saved value is never changed; the screen says
  "Shown lighter on controls so it stays readable on black."
- Selection is never colour alone: swatches show a checkmark and a ring, expose the
  `.isSelected` trait and the value "Selected"; tabs keep their filled SF Symbol and label.
- Very dark swatches get an outline so they stay visible on black.

## 5. Motion

Preset and reset changes cross-fade with a 0.22 s ease; swatch checkmarks use a short spring.
With Reduce Motion both are applied immediately. No looping animation, shader or blur was
added. No frame-rate or battery measurements were taken; none are claimed.

## 6. Coverage audit

All 88 `AppColors.accentPrimary` references in 27 files and the `ListeningStyle.accent` uses in
the analytics dashboard now read the palette (`AppColors.accentPrimary` was removed, so a
missed reference fails to compile). Black text on accent fills became `palette.onAccent`.

| Area | Files |
| --- | --- |
| Root, tabs, search bar | `RootView.swift` |
| Mini-player, Now Playing, slider, shuffle/repeat, sleep timer | `PlayerViews.swift`, `SleepTimerViews.swift` |
| Home, Search, YouTube | `HomeView.swift`, `SearchView.swift`, `YouTubeViews.swift` |
| Library, details, song options | `LibraryView.swift`, `DetailViews.swift`, `SongOptionsView.swift`, `RecordingReplacementViews.swift` |
| Playlist import, matching, acquisition, migration | `PlaylistImportView.swift`, `PlaylistMatchingViewModel.swift`, `MatchingButtonStyle.swift`, `PlaylistAcquisitionViews.swift`, `PlaylistAdditionViews.swift`, `Migration*.swift` |
| Profile, onboarding | `LocalProfileView.swift`, `LocalProfileOnboardingView.swift`, `ProfileComponents.swift` |
| Listening dashboard (hero ring, chart, range control, rankings) | `ListeningComponents.swift`, `ListeningDashboardView.swift` |
| Shared components (section header, empty state, filter chip) | `DesignSystem.swift` |
| Diagnostics | `DiagnosticsView.swift` (its private lime constant removed) |

Entry points: Profile → Personalization → Appearance (replaces the Phase 11.1 "Appearance —
Planned" row) and Settings → Appearance. Both use the same `ThemeService`.

## 7. Tests

| Suite | Covers |
| --- | --- |
| `ThemePresetTests` | Lime default, eight distinct presets, ids round-trip, AA on black, custom distinct |
| `ThemeColorTests` | Canonical hex round-trip, malformed hex rejected, alpha dropped and P3 clamped, `onAccent` for light/dark, contrast lift, determinism |
| `ThemeServiceTests` | Missing/corrupt/unsupported/version fallbacks, preset and custom persistence across "relaunch", coalesced writes and commit, reset, observer notification and no-op selection, write failure, other preferences untouched, no AVPlayer item replacement / library / profile change, synchronous restore |
| `AppearanceSettingsUITests` | Open from Profile and Settings, all presets visible, selection value/trait, reset, custom swatch selection, persistence across relaunch, tab and navigation preserved, screenshots |

`AppearanceSettingsUITests` runs in the existing OtherUI shard (whole bundle minus Library).

**Limitation:** the system `ColorPicker` sheet belongs to UIKit and cannot be driven reliably by
XCUITest. The UI test checks that the picker and the custom swatch exist and that custom
selection works; colour conversion, persistence and contrast for picked colours are unit
tested, and the drag itself is physical check P08–P10.

## 8. Physical acceptance checklist

| # | Check |
| --- | --- |
| P01 | Upgrade from 11.2: app opens in Original Lime, looks unchanged |
| P02 | Profile → Appearance opens; header, preview, eight presets and Custom shown |
| P03 | Settings → Appearance opens the same screen with the same selection |
| P04 | Each preset changes the preview immediately; checkmark + ring on the selected swatch |
| P05 | Tabs, mini-player and Home follow the selected accent |
| P06 | Now Playing slider, play button, shuffle and repeat follow the accent |
| P07 | Library, Search, Downloads and migration screens follow the accent |
| P08 | Custom: system picker opens without opacity; preview updates while dragging |
| P09 | Custom HEX shown and correct; very dark colour shows the "shown lighter" note |
| P10 | Custom colour persists after force-quit and relaunch |
| P11 | Preset persists after force-quit and relaunch; no Lime flash on launch |
| P12 | Restore Original Theme returns to Lime; custom colour still available |
| P13 | Changing theme while music plays: no pause, skip, restart or stutter |
| P14 | Changing theme keeps the selected tab, navigation stack and scroll position |
| P15 | Your Listening: ring, chart, range control and rankings use the accent; values unchanged |
| P16 | Text on accent buttons readable for every preset and a dark custom colour |
| P17 | Error, warning and destructive colours unchanged under every theme |
| P18 | VoiceOver announces preset names and "Selected" |
| P19 | Reduce Motion: theme changes apply without animation |
| P20 | Large Dynamic Type: swatch grid and labels remain usable |

## 9. Developer-reported physical acceptance — 2026-11-17

Developer confirmed Phase 11.3 installed on a physical iPhone and reported all ten tests in the **conversation's user-facing acceptance checklist** as PASS.

| User-facing ID | Reported check | Result |
| --- | --- | --- |
| P01 | All eight preset colors work | **PASS** |
| P02 | Custom color picker works | **PASS** |
| P03 | Colors update immediately throughout the app | **PASS** |
| P04 | Now Playing controls and sliders update | **PASS** |
| P05 | Analytics charts and highlights update | **PASS** |
| P06 | Selected theme survives force-closing and reopening | **PASS** |
| P07 | Reset restores original lime green | **PASS** |
| P08 | Music continues playing while changing themes | **PASS** |
| P09 | Profile, playlists, downloads and analytics remain intact | **PASS** |
| P10 | No visual glitches, clipping or unreadable text | **PASS** |

**Outcome: 10 PASS, 0 FAIL, 0 skipped (developer-reported, not independently observed).**

**Mapping caution:** These are *not* the same ID-to-condition mappings as the repository's more detailed P01–P20 checklist in §8. The user results do not independently certify unreported checks, including VoiceOver, Reduce Motion, Dynamic Type, or every specific persistence/contrast edge case.

### Integration-readiness evidence

- **Physical acceptance:** PASS (10/10).
- **Branch:** `feature/phase-11-03-themes`, at source `7a09328d2a843c3d8b874d07d28fd7e0dfddf17b`, initially ahead of `develop` by one commit, behind by zero.
- **Unsigned IPA builds:** [run #104](https://github.com/T-h07/MuzikBelesh/actions/runs/44162507202) and [run #105](https://github.com/T-h07/MuzikBelesh/actions/runs/44177503542) SUCCESS, both sourced from the feature SHA above.
- **CI:** [run #291](https://github.com/T-h07/MuzikBelesh/actions/runs/44162445256) CANCELLED. Static checks passed. Four regression shards were canceled and did **not** establish pass/fail. The build-and-test gate failed because it required `SHARDS=success` but received `SHARDS=cancelled` (not a demonstrated compiler or test assertion failure).
- **Assessment:** Device-accepted and structurally non-divergent; appropriate for an explicitly owner-approved integration into `develop` if the owner accepts incomplete native regression verification. If full native CI is mandatory, do not mark that gate passed.
- **No merge authorized by this documentation update.** Keep `release`, `main` and public tags unchanged pending separate approval.
