# Persistence testing

`Phase2StorageTests` uses isolated temporary sandbox roots and covers fresh migration, migration reopening, schema presence, stable track IDs, content-hash lookup, missing-file state, path traversal rejection, deterministic streaming hashing, settings persistence, and playlist repository persistence. The existing Phase 0 and Phase 1 tests remain in the same generated scheme.

The GitHub Actions macOS simulator is authoritative for Swift and AVFoundation compilation. Physical Files import, termination/relaunch, SideStore signing, and independent playback remain device acceptance checks; they must not be reported as completed from Windows-only development.
