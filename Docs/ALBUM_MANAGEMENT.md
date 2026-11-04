# Managed albums

Albums are primary track metadata, not a second playlist membership table.
Each track has zero or one `albumID`, plus a nullable persistent `albumPosition`.
Playlist memberships, track identities and original encoded audio are independent.

Migration v010 adds album release year, description and management source, and the
track position. It preserves existing album/artist/track IDs and all files. Each
existing album receives positions in its previous order: dateAdded ASC, then track
ID ASC. New imports append; explicit reorder replaces positions in one transaction.
Gaps after moving/deleting a song are harmless; the next album mutation normalizes
its complete order. Library sorting never changes it.

Manual albums have UUID identities and persist while empty. Editing an imported
album keeps its ID and promotes it to managed. Duplicate display names never merge
managed albums. Imports reuse only one unambiguous unmanaged title/artist parent;
otherwise they create a separate UUID parent. A metadata title edit keeps the
current primary assignment when the album name/artist are unchanged.

Moving membership updates albumID, albumArtist and indexed search text atomically.
The track performer is unchanged. Removing membership or deleting an album clears
the assignment and exposes the songs in virtual Unassigned Songs, which has no
albums-table row and cannot be deleted as an album. No audio, likes, playlists,
history, queue entries or playback items are deleted by album operations. The
active playback context stays a snapshot until a collection is started again.

Album artwork uses ManagedLibraryFiles' existing prepare/commit/recover journal,
reference-aware cleanup, constrained paths and thumbnails. Failed saves clean staged
covers; replacement/removal/deletion clean only unreferenced managed artwork.
Interrupted cleanup remains recoverable at startup.

Published GRDB snapshots feed shared search and artist views. Empty managed albums
and their album artists stay searchable. Album name, artist, description and year
participate in normalized literal matching. Filesystem work uses the existing
mutation gate off the main actor. The UI supports creation/editing, song selection,
native drag and accessible reorder buttons, confirmed deletion, Play and Shuffle.
