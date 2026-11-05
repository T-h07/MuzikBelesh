# Phase 7.1 background audio downloads

Build 178 deliberately used ephemeral, foreground-bound media tasks so it could reject redirects before contacting the next host. Leaving the foreground cancelled the worker. Phase 7.1 delegates media bytes to the iOS background transfer daemon. Stream preparation, SQLite writes, validation, artwork and import still require app execution.

## Ownership and lifecycle

AppBootstrap supplies one application-lifetime BackgroundTransfers instance. It recreates two fixed sessions, com.th07.muzikbelesh.downloads.v1.wifi and com.th07.muzikbelesh.downloads.v1.mobile. Both enable launch events and connectivity waiting, disable discretionary scheduling, cookies, credential storage and response caching, and permit expensive and constrained links. The resource timeout is six hours. The wifi configuration and each strict request independently disable cellular access. Search, metadata and artwork retain their separate transports. iOS controls scheduling, including delays for work initiated in the background.

DownloadManager resolves locally, creates a suspended download task, tags it with the job UUID and a new attempt UUID, commits the mapping, then resumes the task. Migration v012 adds nullable session, task number, generation and bounded refresh fields to download_jobs with a unique session/task index. Existing rows remain valid. SQLite stores no media URL or resume blob. The system necessarily owns the temporary signed request while it performs the transfer.

Launch and foreground reconciliation enumerate both sessions before scheduling. A surviving task must match the job, generation, session and task number. The matching task contributes a slot and retains its progress. Unowned or superseded tasks are cancelled. Missing tasks recover complete staging first, then queue a fresh resolution if necessary. A suspended, mapped task can be resumed after an interrupted handoff. A cancelled or completed job cannot accept callbacks from an old generation.

Ordinary background transitions stop scheduling new app workers. An active system task keeps its ownership. The network monitor gates new requests and informs the Wi-Fi waiting label. A running strict session relies on the operating system to exclude cellular when the app cannot observe the path. Enabling Wi-Fi-only invalidates unrestricted attempts and cancels them. Disabling it permits new unrestricted attempts; existing Wi-Fi tasks retain their original configuration. Reducing concurrency lets current transfers finish.

## Safe delivery

The serial delegate samples progress before delivery to the main actor. Display cadence is approximately 0.5 seconds and progress-only SQLite checkpoints are eight seconds apart. Lifecycle changes and final bytes are committed separately. Numeric URLSession transaction metrics report body bytes and timings when available. Physical throughput depends on the network and upstream service.

The download delegate checks the final URL, HTTP status, MIME type, size limit (1 GiB) and content length. It moves the temporary file synchronously into a generation-specific incoming file before returning. The terminal callback promotes the file to job staging, records exact bytes and releases ownership. On launch an authorized incoming file can be promoted if the task disappeared. The existing verifier, duration audit, hash, import journal, provenance and duplicate checks apply before completion. Foreground return can finalize staged bytes without repeating extraction. UIKit completion handlers are keyed by session. The serial delegate and main-queue delivery order puts durable transfer bookkeeping ahead of the finish-events notification. The app calls UIKit on the main queue without waiting for artwork or import.

Pause and cancel revoke durable ownership before cancelling the system task. Resume/retry starts a new representation from zero. Opaque resume data can contain expiring credentials and cannot safely be concatenated across refreshed representations, so this version does not persist it. A rejected signed request (401/403/410) receives one automatic fresh resolution, preserving the selected quality. Further failure requires action. A force quit can cancel background tasks and suppress relaunch until the owner opens the app. Reboot, coverage, free space, file protection and OS scheduling can delay completion.

## Redirect security

Only trusted HTTPS Googlevideo media URLs may start a transfer. HTTP credentials, unexpected ports and untrusted final destinations are rejected. Apple background sessions may contact intermediate redirect hosts without per-hop interception. Initial and final validation cannot prove that all intermediate hosts were trusted, or recover bandwidth already spent. Invalid responses never enter the import pipeline. This change accepts that residual risk to support native background downloads. No new entitlement, background audio workaround or third-party transfer backend is used.

[Apple background download guide](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) · [Background configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) · [UIKit event handoff](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:handleeventsforbackgroundurlsession:completionhandler:))

## Verification and physical acceptance

The PR records exact CI evidence. Deterministic tests inject system tasks and reconstruct the manager over SQLite. Simulator tests cannot establish continued transfer during physical suspension. All cases below await iPhone 13 Pro Max testing.

| Case | Procedure and pass condition | Device |
|---|---|---|
| P0 Lock | Begin an authorized long download, note bytes, lock for a minute, unlock. The same job advances or finishes; play it offline. | NOT RUN |
| P1 Switch | While bytes increase, use Safari or YouTube, then return. Verify continuation without a restart. | NOT RUN |
| P2 Background finish | Leave the app until completion, reopen and verify one playable library entry. | NOT RUN |
| P3 Wi-Fi only | Disconnect Wi-Fi with cellular available. Verify no cellular media use, reconnect and finish. | NOT RUN |
| P4 Restoration | Observe ordinary suspension and, if encountered, system termination/relaunch. Verify the same task or safe staged-file recovery. | NOT RUN |
| P5 Controls | Pause/cancel one job, retry, and verify late callbacks cannot revive the old attempt. | NOT RUN |
| P6 Concurrent | Start multiple jobs, switch away, return and verify their independent progress, output and configured limit. | NOT RUN |
| P7 Upgrade | Install over 178 with the same SideStore identity. Check existing tracks, artwork, edits, playlists and playback state. | NOT RUN |
| P8 Force quit | Explicitly force quit, reopen, observe whether iOS cancelled the transfer; verify safe recovery without duplicates. | NOT RUN |
| P9 Offline | Disable both networks after completion, seek and play to the correct endpoint, then test locked playback and controls. | NOT RUN |

Rollback planning: finish or cancel outstanding background jobs before changing builds. Retain the library and database. An older binary cannot manage the new session identifiers or guarantee a schema downgrade. Prefer a forward fix on the additive schema. Do not delete app data to recover a transfer.
