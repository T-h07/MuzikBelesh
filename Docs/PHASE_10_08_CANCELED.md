# Phase 10.8 — Spotify Share Extension & Direct Playlist Integration

**CANCELED — Spotify API integration replaced by existing Exportify CSV / Spotify file-import workflow.**

Phase 10.8 was never merged and was never released. After testing an unsigned test IPA,
the project decided that direct Spotify Web API access (OAuth, developer-app registration,
Development Mode user limits and owner-only playlist access) adds complexity and external
dependencies without enough benefit over the existing file import.

The implementation lived only on `feature/phase-10-08-spotify-sharing` (commits `3faf205`,
`49f3fa5`, `a6cbf36`, based on the Phase 10.7 merge `c2be900`). That branch was retired. None
of its code is in `develop`, `main` or `release`:

- Spotify OAuth/PKCE and Keychain tokens
- the Web API client
- Spotify link recognition in the Share extension
- the typed version 2 share inbox
- the `v023_spotify_pending_imports` table
- the `SPOTIFY_CLIENT_ID` / `SPOTIFY_REDIRECT_URI` build settings

## Supported Spotify migration

```text
Spotify Playlist
       │
       ▼
Exportify CSV / Spotify Data Export (JSON or ZIP)
       │
       ▼
Muzik Belesh → Import Preview → User Confirmation → Matching & Downloads → Offline Playlist
```

The Phase 10.0–10.7 import, matching, review, acquisition and playlist features are
unchanged. The `.spotifyAPI` source value remains in the migration model and schema
(Phase 10.0) only for compatibility; it is not an active integration. YouTube sharing is
the Phase 8 extension, unchanged.

## Phones that installed the Phase 10.8 test IPA

- **Database.** That build applied `v023_spotify_pending_imports`. GRDB skips applied
  migrations it doesn't recognize (it does not fail), so a Phase 10.7-based build opens
  the database normally. The leftover table is unused and harmless. Library, playlists and
  migrations are untouched.
- **Keychain.** The test IPA had no Spotify Client ID, so no Spotify credentials could be
  stored.
- **Share inbox.** The test build rewrote the App Group file `PendingYouTubeLinks-v1.json`
  as a version 2 queue. Before this fix, a Phase 10.7 build rejected that file
  indefinitely:
  - every YouTube share failed with "Could not save the link"
  - "Could not read the shared link inbox" appeared on every launch

  `SharedLinkInbox` now reads such a queue once:
  - YouTube shares keep their IDs, timestamps and order
  - pending Spotify playlist shares are dropped
  - the original bytes are copied to `PendingSharedLinks-v2-backup-<uuid>.json`
  - the file is rewritten as version 1

  Unknown versions, unknown kinds and invalid records are still rejected and left
  untouched. Tests: `SharedLinkInboxTests.testCanceledPhase108VersionTwoQueueIsRestoredOnce`
  and `testUnknownVersionTwoContentStaysRejectedAndUntouched`.
