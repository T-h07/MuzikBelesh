# Audio downloads

In Video Details, choose a quality and tap Download Audio. View in Downloads opens the shared queue. Play starts the stored track using the existing player. Only save media you are authorized to download.

## Scheduling and persistence

One main-actor DownloadManager owns queue mutations, active workers and published presentation state. A slot is retained until its cancelled worker returns. Lowering the simultaneous-download preference allows existing workers to finish. Pending jobs run in SQLite position order. Moving two pending jobs exchanges their positions in one transaction. The unique video index and the manager serialize repeat requests. The GRDB repository stores media identity, user-selected quality, metadata, timestamps, byte counts and the final library track ID. The stream URL and URLSession request stay in memory.

The normal path is queued → resolving → downloading → verifying → importing → completed. A strict network policy can hold work in waitingForWiFi. Pause, cancellation and failure require an explicit user action to restart. Interrupted work can restart after connectivity or foreground activity returns. Restarting uses fresh stream resolution and resets transfer byte counts. A rejected media link receives one fresh resolution per scheduling attempt. A failed import retains its validated staging file for retry.

## Media transfer

Each in-process ephemeral URLSessionDownloadTask uses a serial delegate. Only HTTPS googlevideo subdomains with allowed ports and no URL credentials pass the initial and redirect checks. The session disables cookies, credentials and caching, enforces request/resource timeouts and caps a file at 1 GiB. The completion delegate validates status, media type and file length, then moves the temporary file synchronously to Application Support/DownloadStaging. The app reports measured bytes and a smoothed rate. Unknown lengths use an indeterminate indicator.

Wi-Fi-only is enabled initially. NWPathMonitor gates scheduling and the session and request independently disable cellular access. Enabling the restriction cancels existing transfer attempts before rescheduling. This setting covers media bytes. Metadata, search, artwork and stream resolution use their existing transports. An expensive Wi-Fi path may still be used.

The developer selected per-hop redirect validation. Apple's daemon-managed background URLSession always follows redirects without consulting the app. The app therefore interrupts network work on entering the background and restarts it on return. A force quit similarly requires reopening the app. Resume data can contain temporary credentials and is discarded. Playback of already stored audio uses the existing background playback system. [Apple background transfer limitations](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

## Validation, import and recovery

AVFoundation checks for a playable audio-only asset and a compatible AAC, AC-3 or E-AC-3 audio format. The managed import pipeline checks duration, computes SHA-256 by streaming, and journals the permanent file and database insertion. YouTube identity lives in track_sources. Identical audio can reuse an existing track. Matching source and hash can repair a missing file without discarding edits. Download title and channel initialize new library metadata. Available validated artwork is stored in the normal managed artwork directory. Audio can finish when the thumbnail is unavailable.

On launch the storage coordinator completes its file-journal recovery. The manager restores queue positions and requeues unfinished work. It checks existing source provenance before transferring, reuses a completed staged file when available, and marks completion after verifying the persistent track and file. A retry starts at byte zero if staging is unavailable. Signed URLs and partial files are never used to splice two stream representations.

Best Available prefers compatible M4A/AAC and then highest known bitrate. Balanced chooses the compatible rate nearest 128 kbps. Data Saver selects the lowest known bitrate in the preferred format pool. High and Standard preferences migrate in place. Each queued job retains its own choice.

## Verification

DownloadTests exercise real SQLite, preference migration, queue controls, media URL policy and fixture import. Release builds contain only production transport. UI-test fixtures generate AAC audio in isolated storage. The separate opt-in open-movie check resolves and transfers media and reads PCM from the local file. Check the PR for run outcomes. Device acceptance is tracked in PHASE_07_DEVICE_TESTING.md.
