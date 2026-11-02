# Duplicate detection

Local imports use the content SHA-256 as the authoritative duplicate key. The digest is calculated incrementally, so the implementation does not load an entire audio file into memory. The database has a unique index on `tracks.contentSHA256` and the import service checks it before publishing a new file.

Track and source identifiers are separate concerns. A manually imported file receives `local_import` metadata and no YouTube source claim. Identical metadata with different bytes is allowed; identical bytes with different filenames are treated as the same track.
