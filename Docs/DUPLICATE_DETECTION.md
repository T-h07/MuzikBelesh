# Duplicate detection

AudioFileService streams SHA-256 in bounded chunks. tracks.contentSHA256 retains its
unique index. Exact bytes with a different filename reuse the existing track and
avoid a second permanent copy. Edited local metadata is never overwritten.
Same title/artist with different bytes is allowed; hashing is not acoustic fingerprinting
and cannot identify semantic equivalence across MP3/M4A encodings.

Optional source aliases use the existing track_sources table and the pair
(sourceType, sourceIdentifier). Types are normalized, identifiers are opaque and
case-sensitive; URLs are not treated as canonical identities. A matching source ID
reuses the existing track even when encoding bytes differ, preserving the stored
record/file. Hash matches can add additional aliases. Conflicting legacy aliases
resolve deterministically by recorded date/ID without merging or deleting tracks.
No YouTube search, extraction or downloading is added.

The application mutation gate serializes preparations. A second lookup inside the
SQLite write transaction covers independent coordinators; a losing import removes
its own UUID copy and returns the persistent winner. Journals mark duplicate and
rolled-back outcomes; recovery removes only unreferenced files owned by those
operations, not arbitrary Music files.

An exact duplicate can repair a missing managed file at its original path, retaining
stable identity, edits, memberships and likes. Existing different bytes are never
overwritten; their track is marked modified. A source match with different bytes
cannot silently repair a missing older encoding. Pending deletions block repair.
Importing valid audio after a failed operation remains possible.

Isolated tests cover same bytes/different names, same title/different bytes, source
pairs/types, aliases, restart, concurrent single and separate coordinators, edited
metadata, missing-file repair, changed-file preservation and retry after failure.
