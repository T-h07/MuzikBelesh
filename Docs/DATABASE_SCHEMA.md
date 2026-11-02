# Phase 2 database schema

Muzik Belesh uses GRDB 7.11.1 with a `DatabaseQueue` stored privately at `Library/Application Support/MuzikBelesh/muzikbelesh.sqlite`. Foreign keys are enabled before migrations run. All timestamps are absolute `Date` values and all user-owned identifiers are stable UUID strings.

Migrations are registered in `OFFLINE/Storage/DatabaseManager.swift`:

1. `v001_initial_library` — artists, albums, tracks, and track indexes.
2. `v002_playlists_and_likes` — playlists, ordered membership, liked tracks.
3. `v003_playback_and_history` — playback singleton, queue entries, history.
4. `v004_download_jobs` — future download-job records only.
5. `v005_settings_sources_imports` — typed settings rows, source records, and import-operation recovery records.

Tracks reference optional artists and albums. Playlist membership, likes, queue entries, history, sources, and jobs reference tracks. Deleting a playlist never deletes tracks; deleting a track cascades dependent relationship records. The unique `tracks_contentSHA256` index provides content duplicate detection, while source records remain extensible for later YouTube integration.
