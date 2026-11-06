# Local storage

Permanent user-visible files use the app Documents container:

```text
On My iPhone/Muzik Belesh/
├── Music/
└── Artwork/
```

The database stays outside Files in `Library/Application Support/MuzikBelesh/`. Import staging, export copies, and thumbnails use `Library/Caches/MuzikBelesh/{Imports,Exports,Thumbnails}`. `AppStoragePaths` is the single path manager, stores only relative paths in SQLite, rejects traversal, and reconstructs URLs after relaunch.

Documents are exposed with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Imported music is excluded from iCloud backup through the app's storage policy decision point in the coordinator; caches remain purgeable. Files are published only after validation and are marked missing if removed externally.
