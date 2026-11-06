# Metadata editing

Track actions / Edit Metadata edits title, artist, album, optional album artist and
cover artwork. The sheet owns a draft; Cancel has no persistent effects. Save failures
keep all typed values and image selection available for retry.

Title is trimmed, Unicode-normalized and must contain 1-300 characters; punctuation
and internal capitalization are preserved. Artist/album names allow up to 300
characters. Parent lookup uses collapsed whitespace, canonical Unicode and case
folding, preserving accent distinctions. Existing matching parent rows are reused;
otherwise parents are created in the same transaction before updating foreign keys.
Album identity combines title and artist identity. Setting an Album Artist such as
Various Artists groups a compilation while retaining distinct track artists.

Missing artist/album fields use Unknown Artist/Unknown Album virtual groups. Album
fallback grouping is per artist; known albums with the same title by different
artists remain distinct. Albums without imported track numbers use a deterministic
Date Added / stable-ID order, not invented track numbers. Empty old grouping records
are retained but excluded from track-derived browsing; referenced artwork is preserved.
Genre is not an inherited persisted field and is not added in this phase.

Edits update the SQLite metadata and timestamp, never embedded tags or audio bytes.
Track ID, managed path, hash, file extension, original filename, playlist membership,
liked state, queue occurrence IDs and history identity remain stable. Export still
returns the original encoded file. No transcoding or audio-tag rewriting is implemented.

ValueObservation updates Library, grouped/detail views, Search and Home. The same
snapshot feeds mini-player and Now Playing; the audio service republishes Lock Screen
metadata/artwork without replacing the player item, resetting elapsed time or changing
the Sleep Timer deadline. See ARTWORK_MANAGEMENT.md for image transaction safety.
