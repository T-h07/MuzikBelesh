# Phase 11.1 — Local Account System, Profile Onboarding & Profile Management

**Status:** implemented on `feature/phase-11-01-profile`, awaiting physical-device acceptance.
Not released: the public release remains v1.1.0 until all Phase 11 work is accepted.

Muzik Belesh now asks for a local profile (a username and an optional photo) on first
launch, and after upgrading from v1.1.0. The profile is stored only on the iPhone, restored
on every launch, and editable from a Profile page opened from the Home header.

**This is not an account or a sign-in.** It has no email, password, token, server,
verification or Apple ID requirement. The username is a display name. It isn't a credential
and it isn't unique.

## Design decisions

| Decision | Reason |
|---|---|
| One SQLite row, guarded by a `slot = 1` primary key | Exactly one profile per installation, enforced by the schema as well as the code |
| No `userID` on library tables, no foreign keys either way | The library belongs to the installation. Profile edits can't affect track, playlist, album, download, migration, history or queue rows |
| Profile read in `AppContainer.init` | The launch destination is known before the first frame, so tabs never flash before onboarding |
| A read failure is a separate `failed` state | A corrupt or unreadable database never routes to onboarding, so nothing can overwrite an existing profile |
| Avatars in `Application Support/MuzikBelesh/Profile` | Separate from music artwork (cleanup can't reach it) and outside Documents (not visible in Files) |
| Draft photo kept in memory until Save / Create | An abandoned onboarding or edit leaves no files behind |
| Lifecycle forwarding moved into the always-mounted gate | Downloads, playback, matching and migrations keep their foreground/background handling while onboarding is visible |

## Storage architecture

```text
AppContainer
 ├─ StorageCoordinator (unchanged) ── DatabaseManager ── v001 … v022, v024
 └─ LocalProfileService (@MainActor, ObservableObject)
       └─ LocalProfileRepository: LocalProfileStoring
             ├─ local_user_profile (GRDB, parameterized SQL)
             └─ Application Support/MuzikBelesh/Profile/avatar-<UUID>.jpg (+ .thumb.jpg)
```

| File | Role |
|---|---|
| `OFFLINE/Profile/LocalUserProfile.swift` | Model, `LocalProfileSchema` (v024), `UsernamePolicy`, `LocalProfileError` |
| `OFFLINE/Profile/ProfileAvatarProcessor.swift` | Image validation and downsampling (`PreparedAvatar`) |
| `OFFLINE/Profile/LocalProfileRepository.swift` | Persistence, avatar file lifecycle, orphan cleanup, fault-injection points |
| `OFFLINE/Profile/LocalProfileService.swift` | Observable state, launch destination, serialized saves |
| `OFFLINE/Features/Profile/LocalProfileOnboardingView.swift` | Onboarding and the storage-error screen |
| `OFFLINE/Features/Profile/LocalProfileView.swift` | Profile page and Edit Profile sheet |
| `OFFLINE/Features/Profile/ProfileComponents.swift` | Avatar views, username field, PhotosPicker controls, Home header button |

## Profile model

| Field | Type | Notes |
|---|---|---|
| `id` | UUID (TEXT, 36 chars, unique) | Generated once at creation; never regenerated |
| `username` | TEXT | Validated display name, at most 120 Unicode scalars in the schema |
| `avatarRelativePath` | TEXT, nullable | Bare file name `avatar-<UUID>.jpg`; no `/` (schema CHECK); nil = default avatar |
| `createdAt` | DATETIME | Never changed |
| `updatedAt` | DATETIME | Changed only by a committed edit that actually changes something |

## Migration identifier

`v024_local_user_profile`, registered by `LocalProfileSchema.register` after
`PlaylistLinkDownloadSchema` (v022, the last v1.1.0 migration). It is append-only and only
creates a table: no existing table, row or file is touched. `v023` is intentionally skipped
because the canceled Phase 10.8 test build applied `v023_spotify_pending_imports` on some
phones. GRDB ignores that unknown identifier, so those databases upgrade too.

```sql
CREATE TABLE local_user_profile (
    slot INTEGER PRIMARY KEY NOT NULL CHECK(slot = 1),
    id TEXT NOT NULL UNIQUE CHECK(length(id) = 36),
    username TEXT NOT NULL CHECK(length(username) BETWEEN 1 AND 120),
    avatarRelativePath TEXT CHECK(avatarRelativePath IS NULL OR (length(avatarRelativePath) BETWEEN 1 AND 128 AND instr(avatarRelativePath, '/') = 0)),
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);
```

## First-launch state machine

```text
                 AppContainer.init → profile.load()
                              │
      ┌───────────────┬───────┴─────────┬──────────────────────┐
  storage nil      read throws      row absent              row present
      │               │                 │                       │
      └──► failed(message) ◄────────┘ noProfile ──Create──► ready
              │      │                     (commit)          │
         Try Again  Continue to Library                     main tabs
         (load())   (session only, no write)
```

| Scenario | Behavior |
|---|---|
| A — new installation | `noProfile` → onboarding → Create commits → Home |
| B — existing profile | `ready` → Home directly; onboarding never shown |
| C — upgrade from v1.1.0 | v024 creates the empty table → onboarding → profile created → existing library unchanged |
| D — killed during onboarding | Nothing was written (the photo is kept in memory), so onboarding appears again. Files from a save interrupted between file write and commit are unreferenced and removed by the next successful load |
| E — storage failure | Error screen with Try Again and Continue to Library. Onboarding is unreachable from this state, so nothing is overwritten and nothing is deleted |

- **Share extension.** Pending shares stay in the App Group inbox while onboarding is
  displayed, because the delivery task lives in the tab interface. They are delivered as
  soon as the tabs mount.
- **Startup services.** Background-transfer reconciliation, acquisition and the migration
  coordinator start in `AppContainer.init` exactly as before.

## Avatar lifecycle

1. **Pick.** The system `PhotosPicker` (`matching: .images`) runs out of process and needs
   no photo-library permission. The picked item is loaded as `Data`.
2. **Prepare (in memory, off the main actor).** `ProfileAvatarProcessor.prepare` checks:
   - the data is non-empty and at most 50 MB (ProRAW stills fit)
   - ImageIO identifies it as an image
   - its declared dimensions are present, at most 20 000 px per side and at most 150 MP
   It then downsamples with the ImageIO thumbnailer (the full bitmap is never decoded),
   centre-crops to a square and encodes:
   - a 512 px JPEG
   - a 128 px thumbnail JPEG
   No source metadata (such as location), Photos URL or asset identifier is kept.
3. **Save.** In order:
   1. Write both files under a fresh `avatar-<UUID>` name, atomically, with
      `completeFileProtectionUntilFirstUserAuthentication`.
   2. Commit the row in one transaction.
   3. Delete the previous files.

   A failure in steps 1–2 removes only the new files, and the previous avatar stays valid.
   If step 3 fails, the old files become unreferenced orphans that the next launch collects.
4. **Remove.** Commit `avatarRelativePath = NULL`, then delete the files. The default avatar
   (a lime person glyph on a dark circle) is shown.
5. **Cleanup.** `removeUnreferencedAvatars` runs only after a successful read. It only
   touches files in the Profile folder named `avatar-<UUID>.jpg` or `avatar-<UUID>.thumb.jpg`.
   It never touches music artwork, playlist artwork or any other file.

A missing or unreadable avatar file falls back to the default avatar. Because each new
avatar has a new file name, the Home header updates immediately after a save.

## Validation rules

Usernames are trimmed of leading and trailing whitespace and newlines, then NFC-normalized:

- **Required.** Empty or whitespace-only names are rejected.
- **Length.** At most 30 user-perceived characters (grapheme clusters), so "José" is 4 and
  a family emoji is 1. There is also a hard limit of 120 Unicode scalars, so a name can't
  grow without bound through stacked combining marks.
- **Characters.** Control characters (Cc), line and paragraph separators, and unassigned or
  surrogate scalars are rejected.
- **Allowed.** Ordinary Unicode in any script, punctuation and emoji.
- **Not unique and never part of a file path.** Avatar files are named by UUID.

## Failure recovery

| Failure | Result |
|---|---|
| Database read error or storage unavailable | `failed` state. Error screen with Try Again; Continue to Library for the session. Nothing written |
| Create or update fails before commit | Transaction rolled back, new avatar files removed, `LocalProfileError.saveFailed` shown; onboarding or editor stays open with the draft |
| Duplicate Create taps | A second call while saving is ignored. If a profile already exists, it is adopted, never replaced |
| Avatar file write fails | No row change; previous avatar kept |
| Old avatar deletion fails | Edit is committed; orphan removed on next launch |
| Corrupt profile row (unparseable id) | `failed` state; never onboarding |

`AppContainer` still opens storage with `try? StorageCoordinator(...)`. If storage itself
can't be opened, Try Again can't reopen it in-process: the message tells the user to
restart. This matches how the rest of v1.1.0 behaves without storage.

## Navigation and UI

- **Home header.** Title, Settings gear (unchanged) and a circular avatar button
  (`home-profile-button`). The avatar button opens `AppSheet.profile`. There is no fifth
  tab, and playback, mini-player and Now Playing navigation are unchanged.
- **Profile page.**
  - Large avatar, username and an Edit Profile button.
  - Account section: Edit Username and Change Profile Picture both open the editor.
  - "Coming Later" section: non-interactive Listening Activity, Appearance and Music
    Sharing rows, each marked "Planned". They are not buttons.
  - A Settings row that presents the existing Settings sheet.
  - A local-only privacy note.
- **Edit Profile.** Draft state. Cancel discards. Save is enabled only for a valid, changed
  draft. Swipe-to-dismiss is disabled while there are unsaved changes. A failed save keeps
  the editor open with an alert.
- **Onboarding.** Pure black, lime accent, white text. Large circular avatar, Add/Change and
  Remove photo, username field with live feedback and a character count, and Create Profile
  (disabled when invalid, a spinner while saving). Return submits.

## Privacy

- The profile is never uploaded, logged, sent to analytics or included in search or
  download requests.
- No telemetry, tokens or passwords were added.
- Avatar files carry no source metadata and are not shown in the Files app.

## Tests

Unit tests are in `Tests/Unit/Profile/LocalProfileTests.swift`:

- `UsernamePolicyTests`: trimming, Unicode, NFC, empty, 30-character limit, the
  combining-mark bound, control characters.
- `LocalUserProfileModelTests`: default avatar fallback, strict managed file names.
- `ProfileAvatarProcessorTests`:
  - valid landscape, portrait and JPEG input; no upscaling
  - non-image, truncated and oversized input
  - dimension limits
- `LocalProfilePersistenceTests`:
  - fresh creation and restore after relaunch
  - single-profile schema guarantee
  - identity, creation-date and modification-date rules
  - rollback on injected commit and file-write faults
  - avatar replacement and removal
  - delayed orphan collection
  - cleanup that never touches artwork or unrelated files
  - unsafe path rejection
  - unchanged library rows
  - no foreign keys
- `LocalProfileUpgradeTests`:
  - a database rewound to the exact v1.1.0 schema upgrades with byte-identical library rows
    and then routes to onboarding
  - the canceled v023 coexists
  - reopening is idempotent
- `LocalProfileServiceTests`:
  - launch destinations
  - duplicate submissions
  - adopting a profile created elsewhere
  - read failure that never routes to onboarding, then recovers
  - nil storage
  - interrupted onboarding
  - edit identity, and failure that keeps state

UI tests are in `Tests/UITests/LocalProfileUITests.swift`:

- A new user sees onboarding with no tabs, creates a profile, keeps the fixture library and
  survives relaunch.
- Invalid names are blocked.
- An existing user skips onboarding; the avatar opens Profile; there are still four tabs.
- Edit Cancel preserves the name; Save persists across relaunch.
- A storage read failure shows the error screen (not onboarding) and Try Again recovers.

Test harness changes:

- Reset UI-test libraries now seed a profile ("UI Listener") so historical suites still
  land on Home. `--profile-onboarding` skips the seed, and `--profile-load-failure` injects
  a failing first read. Both are DEBUG-only.
- `Phase1UITests` now uses an isolated reset library instead of the simulator's real
  container, which would otherwise show onboarding.

CI results for the pushed commit are recorded in the delivery report, not here, so they can't go stale.

## Known limitations

- **PhotosPicker isn't automated.** Simulator UI tests can't drive the system picker.
  Photo selection, replacement and removal through the UI are verified only by unit tests
  of the same code paths, plus the device checklist (P05, P08).
- **Storage that can't be opened at launch** needs an app restart to recover.
  Continue to Library keeps the rest of the app usable for that session.
- **One profile per installation.** There are no multiple profiles and no
  profile-scoped libraries.
- **No crop editor.** Photos are centre-cropped to a square automatically.
- **No backup or export of the profile yet.** Library export and import is planned for
  Phase 11.4. The profile is included in ordinary iOS device backups of app data.

## Physical acceptance checklist (iPhone 13 Pro Max, SideStore)

| ID | Check | Result |
|---|---|---|
| P01 | Install the Phase 11.1 IPA over v1.1.0 without uninstalling | |
| P02 | Existing music, playlists, artwork and downloads remain available | |
| P03 | First launch prompts for a local profile (no tabs visible behind it) | |
| P04 | Username-only profile creation succeeds and opens Home | |
| P05 | Optional profile picture selection succeeds (including a HEIC photo) | |
| P06 | Profile opens from the Home avatar | |
| P07 | Username can be edited and saved; Cancel discards | |
| P08 | Profile picture can be replaced and removed (default avatar shown) | |
| P09 | Force-quit and reopen preserves the profile and photo; no onboarding | |
| P10 | Empty, whitespace-only, 31-character and pasted multi-line names are refused; a non-image or very large file is refused with a message | |
| P11 | Playback, downloads and imported playlists still work | |
| P12 | Existing settings and the Share extension still work (share a YouTube link while onboarding is shown, finish onboarding, confirm it opens) | |

The key risk is P01–P03: an in-place upgrade from v1.1.0 that creates the first profile
without changing existing data.
