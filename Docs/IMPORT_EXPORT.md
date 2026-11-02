# Audio import and export

Phase 2 accepts `.m4a`, `.mp3`, `.wav`, `.aiff`, `.aif`, and `.caf` files. `AudioFileService` validates that the URL contains an audio track through AVFoundation, reads common title/artist/album/artwork metadata, computes a streaming SHA-256 checksum, and copies bytes in bounded chunks.

The import sequence is security-scoped access, metadata validation, same-volume staging in Caches, hashing, duplicate lookup, atomic destination publication, and a database transaction that records the track and import operation. Failed staging is cleaned up; committed records never point at a cache path. A matching SHA-256 returns the existing track without creating a second record.

Export resolves the stored relative path, copies the original bytes to the selected destination, and compares source and destination hashes. Missing managed files produce an explicit error instead of an apparently successful export.
