# Persistent library architecture

`AppContainer` owns one StorageCoordinator, AudioPlayerService and MusicLibraryService.
GRDB/SQLite is authoritative. Existing StoredTrack/Artist/Album/Playlist/LikedTrack
models and repository tables are reused. MockMusicStore is retained for fixtures,
not production Library, Home, albums, artists, playlists or local Search.

LibraryRepository implements transactional validation, membership, likes, metadata
relationships and parameterized queries. MusicLibraryService projects one GRDB
ValueObservation snapshot on the main actor, with cached track/name lookups and
group collections. Views never run raw SQL. Direct repository writes, imports and
availability changes all refresh the projection. There is no polling timer.
Snapshot observation includes listening-history IDs for Home, not the high-frequency
playback-position table. Changes publish updated system metadata without replacing
the active AVPlayer item.

Migration `v009_library_management` adds albumArtist, normalizedTitle/searchText,
context-kind/source metadata, file-operation recovery records and library indexes.
Versions v001-v008 are unchanged. The migration backfills search/lookup keys while
retaining parent/track IDs, memberships, likes, queues, history and timer state.
The Phase 4-to-5 upgrade test populates a real v008 database before migration.

The database stays in Application Support. Audio/artwork stay under Documents/Music
and Documents/Artwork. Recoverable deletion files use Application Support/DeletionStaging,
which is deliberately not a purgeable cache. Relative-path containment checks apply
to all managed file access.

A mutation gate serializes filesystem transitions for the application coordinator;
SQLite write-lock duplicate rechecks also protect independent coordinators. Expensive
image/file work and search execute away from the main actor. Initial recovery is
performed before missing-file reconciliation so prepared deletions can be restored.

Playback order is a snapshot of the collection at Play. Reordering/deleting a
playlist or changing like/group membership does not restart the current song.
New starts read the current persisted order. Permanently removed/unavailable songs
are filtered from active navigation. An explicit queued song outside a snapshot is
inserted after the current item so subsequent linear navigation resumes that context.
Restoration retains ordered IDs even if the original playlist was later deleted.

Each imported track may have multiple source aliases. Artist identity uses canonical
Unicode, collapsed whitespace and case folding while preserving accents; albums
combine normalized title with artist/album-artist identity. Unknown metadata uses
virtual groups, not duplicated parent records. Empty parents are retained and hidden
from track-derived groups, preserving their identity and referenced custom artwork.

Physical device acceptance remains separate from automated success.

Universal search uses LibrarySearchEngine/LibrarySearchResults over an immutable
observed snapshot, with normalized substring matching on a detached task. Both search
surfaces share LibrarySearchSession generation/cancellation protection and the same
result/destination components. Scopes restrict those results without rewriting the
query or playlist membership order. RootView owns native enum-valued search focus;
fields, tab/presentation transitions and result actions use that single focus binding.

Build 65's physical E failure is recorded separately from its A-D/F-J PASS report.
Default CURRENT_PROJECT_VERSION and MARKETING_VERSION are shared at project level,
and simulator/device CI supplies one build value to app and extension. Compact tests
exercise installation, layout and keyboard interaction rather than accepting an
installation failure as a layout result.
