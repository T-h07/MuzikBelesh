# Local storage

Permanent user-visible files use the app Documents container:

```text
On My iPhone/Muzik Belesh/
├── Music/
└── Artwork/
```

The database stays outside Files in `Library/Application Support/MuzikBelesh/`. Import staging, export copies, and thumbnails use `Library/Caches/MuzikBelesh/{Imports,Exports,Thumbnails}`. `AppStoragePaths` is the single path manager, stores only relative paths in SQLite, rejects traversal, and reconstructs URLs after relaunch.

Documents are exposed with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Imported music is excluded from iCloud backup through the app's storage policy decision point in the coordinator; caches remain purgeable. Files are published only after validation and are marked missing if removed externally.

## Persistent imported playlist metadata

Migration-managed playlists retain every source occurrence in SQLite independently
of local audio. StorageCoordinator recovers migration associations after existing
file-journal and missing-file recovery. Missing/deleted recordings become placeholders;
source metadata and ordering survive. Rendering checks file availability without
whole-file hashing; association verifies the audio and stored hash. See
[Phase 10.1](PHASE_10_01_PERSISTENCE.md) for transactions and recovery policy.
