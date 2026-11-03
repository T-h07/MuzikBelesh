# Phase 5 physical iPhone acceptance

## Rejected physical build 65 — developer report, 2026-11-03

Device: iPhone 13 Pro Max. iOS version: **NOT PROVIDED**.
Source: `b9cd89008d9c3e8c6604eab10ae30fabc1558766`, version 0.1.0 (65).
The PASS/FAIL results below were reported by the developer, not observed by this
agent. Phase 5 is NOT ACCEPTED. PR #6 must remain open while E is failing.

Two search defects were reported:

1. Search tab: focus the search field, open the keyboard, then attempt dismissal
   or a tab change. The keyboard obstructs navigation and remains visible; the
   developer had to force-close the application. No reliable submit/Done, scroll,
   result-selection or tab-transition focus cleanup was implemented in build 65.
2. Create a playlist, artist or album, then search for it. Search only returned
   track rows; the Library field disappeared in the other category branches, so
   playlists/artists/albums were not searchable as entities.

Separate CI run 41700080334 passed the primary simulator tests but failed compact
installation before layout assertions: `bundleVersion must be set in placeholder
attributes for an app extension placeholder`. The compact command omitted the
shared version override, and the extension lacked a valid default build number.
This is an installation/configuration failure, not a layout assertion result.

The next build must be installed over the existing application. Check E remains
FAIL until physical keyboard and universal-search retests pass; passing CI cannot
change that result. The other checks retain their reported build-65 PASS evidence
and must be monitored for regression during the update.

Status: **REJECTED — build 65 fails acceptance check E; fixes require physical retesting**.
Use iPhone 13 Pro Max. Record iOS version, version/build/embedded SHA, workflow URLs,
action order and timestamps. Use PASS / FAIL / NOT RUN / BLOCKED. No result below
is accepted merely because simulator tests pass.

Install the Phase 5 IPA in place through SideStore. Verify the app and Share extension
retain their identities and existing imported music, history, queue and timer state.
Do not delete the installed application to work around migration failures. The PR
contains the exact final source, build, artifact and SHA256 manifest.

| Test | Procedure | Result |
| --- | --- | --- |
| A: import | Import ten MP3/M4A files; all appear with valid metadata and play. Reimport identical bytes under another filename; no extra track/copy. | PASS — developer reported, build 65 |
| B: playlists | Create three, rename/edit descriptions/covers, add multiple songs, share songs between playlists, remove from one only, drag reorder, play saved order. Delete a playlist; audio/likes/other playlists remain. | PASS — developer reported, build 65 |
| C: metadata | Rename/title, artist, album and optional album artist; replace JPEG/PNG artwork; Cancel another edit. Check groups, Home, Search, mini/full player and Lock Screen update without restarting audio. | PASS — developer reported, build 65 |
| D: likes | Like/unlike from Library, detail screens and Now Playing. Liked Songs reflects one consistent persisted state. | PASS — developer reported, build 65 |
| E: search/sort | Search title/artist/album, Unicode and literal %/_; test all seven sorts. Custom playlist order stays intact. | FAIL — developer reported, build 65 |
| F: restart | Force-close/relaunch. Ten songs, edits, art, playlists, membership, order, likes, sort and playback context remain. | PASS — developer reported, build 65 |
| G: deletion | Remove membership and cancel song deletion first. Confirm permanent deletion of a dedicated test song only; verify file removal, reference cleanup and preservation of unrelated music. Delete a currently playing dedicated song; other queue entries still work. | PASS — developer reported, build 65 |
| H: offline | Enable Airplane Mode; browse/search/organize and play imported tracks. No network is needed. | PASS — developer reported, build 65 |
| I: regressions | Seek/natural EOF, Previous at first Library index with Shuffle Off/On, Repeat Off/All/One, explicit duplicate queue entries, Bluetooth/Lock Screen, a locked one-minute Sleep Timer. | PASS — developer reported, build 65 |
| J: update | Existing Phase 4 database upgrades in place with all original audio and relationships. Export still produces original encoded bytes. | PASS — developer reported, build 65 |

While playing a playlist, reorder or delete that playlist and edit current metadata:
current item/time must continue; the active order stays a snapshot. Start it again
to use the new persisted order. A permanently deleted track is removed from navigation.

If anything fails, preserve the app container and export Settings / Diagnostics before
relaunch; include the steps and identifiers. Do not invent device results. Critical
data-loss or playback failures block automatic integration. Once all mandatory gates
and required evidence pass, Phase 5's authorized automatic merge into develop can
proceed without a separate routine approval. Never merge into release or start Phase 6.
