# Playlist management

Library / Playlists / Create Playlist creates a UUID-backed row. Names are trimmed,
Unicode-normalized, whitespace-collapsed and limited to 120 characters; empty names
are rejected. Duplicate names are allowed. Description is optional (up to 2000
characters). Cover artwork is optional. Save uses draft values; Cancel writes nothing.
Name, description and a new cover are committed together after image validation.
Renaming preserves ID, creation time, memberships and order; modified time changes.

Add Songs browses/searches real tracks and supports multiple selection. Existing
memberships are marked and disabled. The composite playlist/track primary key keeps
one occurrence per playlist; a track may belong to unlimited different playlists.
Batch addition validates all IDs and commits transactionally. Phase 4 queue occurrences
retain separate IDs and can deliberately repeat the same track.

Playlist Detail has Play, Shuffle, Add Songs, Edit and Reorder. Native List drag
reordering and accessible up/down buttons use the same atomic repository reorder.
The requested ID set must equal current membership; duplicate/missing/stale orders
are rejected. Database failures retain the canonical order. Removing a song closes
position gaps, never deletes its audio, likes, other memberships or track row.

Delete Playlist requires confirmation. Cascades remove only its associations;
tracks, files, likes and unrelated playlists remain. Artwork cleanup checks all
track/album/artist/playlist references and is journaled for recovery.

Playback uses the persisted custom order captured at start. Live reorder or playlist
deletion leaves the current item/elapsed time and active ordered snapshot intact.
The next collection start reads the new order. A permanently deleted song is removed
from that snapshot and its explicit queue occurrences; other songs are preserved.
