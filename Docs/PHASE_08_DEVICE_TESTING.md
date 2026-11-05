# Phase 8 iPhone acceptance

Use the candidate and manifest linked in the PR. Record iPhone model, iOS version, SideStore version, source build, candidate build and signing outcome. Install over **0.1.0 (184)** with the existing signing identity, keeping the Share extension enabled. Record the baseline track count, representative downloads, playlists, settings and a known playable track before updating. Preserve the installation if signing fails.

| Case | Exercise and pass condition | Physical result |
|---|---|---|
| P0 YouTube | Share a normal video, select Muzik Belesh, check its ID and Save Link. Tap Done, open the app yourself, inspect the prefilled link, verify Video Details, choose quality and start Download Audio. Record the explicit app-opening step. | NOT RUN |
| P1 Safari | Share a watch page. Save and open the app. Verify inspection of the same ID with no paste. | NOT RUN |
| P2 Shorts | Share a Shorts URL with tracking. Verify the canonical watch URL has the original ID. | NOT RUN |
| P3 Invalid | Share a non-YouTube page or malformed ID. Expect an error, with no new import or job. | NOT RUN |
| P4 Cold launch | Terminate Muzik Belesh, save a link from another app and launch. Verify one prefilled sheet and no repeat after dismissal and relaunch. | NOT RUN |
| P5 Warm launch | Leave a manual import, settings sheet or library editor open. Share a video elsewhere. Return, finish the current sheet, then inspect the pending link. Check normal manual import starts empty. | NOT RUN |
| P6 Multiple shares | Save A, B and A again before opening. Process A then B once each without overwrites. Verify the download manager still deduplicates the same source. | NOT RUN |
| P7 Signing | Record each signed bundle ID and the requested vs granted App Group for both processes where inspectable. Check Settings → Diagnostics, then verify the extension can save and the app can read that same event. | NOT RUN |
| P8 Upgrade | Install over Build 184. Compare library, albums, artists, playlists, artwork, settings, history, queue and existing downloads with the recorded baseline. | NOT RUN |
| P9 Background transfer | Start a download from shared Video Details. Switch apps or lock, return, and verify the job completes once in Library. | NOT RUN |
| P10 Offline playback | Disable network, play the completed download, seek near the end and check duration and controls. | NOT RUN |
| P11 Registration | Relaunch and verify both hosts still offer the extension and can deliver after the in-place update. | NOT RUN |
| P12 Blocker diagnosis | If signing or transfer fails, record the exact SideStore or UI error, which target failed, and whether the app's group probe succeeds. Record the installed group values if available. | NOT RUN |

If a signed IPA is available on macOS, unpack it and run `codesign -d --entitlements -` on the app and the embedded appex individually. Decode each embedded.mobileprovision locally with `security cms -D -i` and compare its application-groups grant with the signature. Record only the relevant group/identity findings. Keep certificates, profiles and private paths out of the PR.

Automatic foregrounding from Share is **BLOCKED** by the extension point. Record explicit opening separately from passing link delivery. Both processes need matching signed group access. A screen showing the recognized URL alone is insufficient. Physical acceptance and merge require the user's confirmation.
