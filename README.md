# Muzik Belesh

Native SwiftUI iPhone music player, iOS 17+, with a persistent offline library,
AVFoundation playback, background audio and Lock Screen controls. Windows supports
editing/Git; GitHub Actions macOS builds and tests the application. The canonical
bundle identifier remains `com.th07.muzikbelesh`.

Phase 8 build 189 was accepted on-device and merged into `develop` at
`b938612`. Phase 9 on `feature/phase-09-release` prepares the **1.0.0 release
candidate** with reliability and performance hardening. Physical acceptance and
explicit publication approval remain pending; the stable release is not published.
Production screens use the persistent SQLite library; mock catalogs are Debug-only.

## Use

Import multiple local audio files in Library. Create/edit playlists, add/remove
songs and reorder them. Like songs from their action menu or Now Playing. Edit
Title, Artist, Album, optional Album Artist and artwork from Edit Metadata. Edits
change application metadata only; audio bytes, hashes, managed paths and identities
stay intact. Export returns the original encoded audio.

Library → Albums supports persistent empty albums, artist/year/description/artwork,
song assignment, custom order, Play/Shuffle and confirmed deletion. Each song has
one primary album and can belong to any number of playlists. Untagged songs appear
under Unassigned Songs. Deleting an album preserves its songs and ongoing playback.

Library and Search find songs, albums, artists and playlists without a network request.
All groups matches with counts; category filters keep the entered query. Search defaults
to Your Library. Search/Done, scrolling and tab changes dismiss the keyboard. Seven
sort modes persist between launches. Each playlist keeps its own custom order.
Playback captures a collection's current order; membership/reorder edits affect
future starts. Permanent track deletion removes it from the active snapshot and
all relevant references; deleting a playlist never deletes music.

## Build and validation

Run `xcodegen generate` on macOS, then build/test the `OFFLINE` scheme. CI runs all
regressions, SQLite/filesystem tests, the ten-track lifecycle and UI workflows.
`Build unsigned IPA` publishes `OFFLINE-unsigned-IPA` plus a provenance/SHA256
manifest. SideStore signs the unsigned app and extension; update in place to retain
the existing application container.

YouTube mode in Search supports search, pagination, details and queued audio
downloads with quality and Wi-Fi preferences. Native transfers reconcile after
backgrounding. Share a YouTube/Safari link to Muzik Belesh, then manually open the
app to finish the validated handoff. Downloads never start solely from sharing.

## Documentation

- [Release audit](Docs/PHASE_09_RELEASE_AUDIT.md) and [15-feature matrix](Docs/PHASE_09_FEATURE_MATRIX.md)
- [Performance evidence and limits](Docs/PHASE_09_PERFORMANCE.md)
- [Candidate device checklist P0–P24](Docs/PHASE_09_DEVICE_TESTING.md)
- [Release gates](Docs/PHASE_09_RELEASE_CHECKLIST.md) and [known limitations](Docs/KNOWN_LIMITATIONS.md)

- [Library architecture](Docs/LIBRARY_ARCHITECTURE.md)
- [Playlist management](Docs/PLAYLIST_MANAGEMENT.md)
- [Metadata editing](Docs/METADATA_EDITING.md)
- [Artwork management](Docs/ARTWORK_MANAGEMENT.md)
- [Search and sorting](Docs/LOCAL_SEARCH_AND_SORTING.md)
- [Duplicate detection](Docs/DUPLICATE_DETECTION.md)
- [Safe deletion](Docs/SAFE_LIBRARY_DELETION.md)
- [Physical Phase 5 checklist](Docs/PHASE_05_DEVICE_TESTING.md)
- [Test plan](Docs/TEST_PLAN.md), [Roadmap](Docs/ROADMAP.md), [Sideloading](Docs/SIDELOADING.md)
