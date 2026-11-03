# Phase 5 physical iPhone acceptance

Status: **NOT RUN — awaiting the matching Phase 5 IPA and developer evidence**.
Use iPhone 13 Pro Max. Record iOS version, version/build/embedded SHA, workflow URLs,
action order and timestamps. Use PASS / FAIL / NOT RUN / BLOCKED. No result below
is accepted merely because simulator tests pass.

Install the Phase 5 IPA in place through SideStore. Verify the app and Share extension
retain their identities and existing imported music, history, queue and timer state.
Do not delete the installed application to work around migration failures. The PR
contains the exact final source, build, artifact and SHA256 manifest.

| Test | Procedure | Result |
| --- | --- | --- |
| A: import | Import ten MP3/M4A files; all appear with valid metadata and play. Reimport identical bytes under another filename; no extra track/copy. | NOT RUN |
| B: playlists | Create three, rename/edit descriptions/covers, add multiple songs, share songs between playlists, remove from one only, drag reorder, play saved order. Delete a playlist; audio/likes/other playlists remain. | NOT RUN |
| C: metadata | Rename/title, artist, album and optional album artist; replace JPEG/PNG artwork; Cancel another edit. Check groups, Home, Search, mini/full player and Lock Screen update without restarting audio. | NOT RUN |
| D: likes | Like/unlike from Library, detail screens and Now Playing. Liked Songs reflects one consistent persisted state. | NOT RUN |
| E: search/sort | Search title/artist/album, Unicode and literal %/_; test all seven sorts. Custom playlist order stays intact. | NOT RUN |
| F: restart | Force-close/relaunch. Ten songs, edits, art, playlists, membership, order, likes, sort and playback context remain. | NOT RUN |
| G: deletion | Remove membership and cancel song deletion first. Confirm permanent deletion of a dedicated test song only; verify file removal, reference cleanup and preservation of unrelated music. Delete a currently playing dedicated song; other queue entries still work. | NOT RUN |
| H: offline | Enable Airplane Mode; browse/search/organize and play imported tracks. No network is needed. | NOT RUN |
| I: regressions | Seek/natural EOF, Previous at first Library index with Shuffle Off/On, Repeat Off/All/One, explicit duplicate queue entries, Bluetooth/Lock Screen, a locked one-minute Sleep Timer. | NOT RUN |
| J: update | Existing Phase 4 database upgrades in place with all original audio and relationships. Export still produces original encoded bytes. | NOT RUN |

While playing a playlist, reorder or delete that playlist and edit current metadata:
current item/time must continue; the active order stays a snapshot. Start it again
to use the new persisted order. A permanently deleted track is removed from navigation.

If anything fails, preserve the app container and export Settings / Diagnostics before
relaunch; include the steps and identifiers. Do not invent device results. Critical
data-loss or playback failures block automatic integration. Once all mandatory gates
and required evidence pass, Phase 5's authorized automatic merge into develop can
proceed without a separate routine approval. Never merge into release or start Phase 6.
