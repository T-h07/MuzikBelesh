# Artwork management

The native Photos picker selects cover images in track/playlist editors. JPEG and
PNG are supported; other ImageIO image types can be converted to the same safe JPEG
output. Input is validated as image content and limited to 20 MB. ImageIO downsamples
before rendering: permanent cover maximum dimension 1024 pixels, row thumbnail 256.
The editor previews its draft. Cancel does not mutate records or files.

New files use independent artwork-UUID.jpg and artwork-UUID.thumb.jpg names under
Documents/Artwork. They are never written over the only existing cover. A prepared
SQLite file-operation record precedes file publication. The metadata/reference update
and journal commit occur in one database transaction. Failure cleans the unreferenced
new files; if cleanup fails, its journal remains for retry. Startup reconciles
references to decide whether to preserve a committed new file or remove an abandoned
one. Removal and playlist deletion also create recovery records before dropping the
last reference. Track-deletion journals retain the old artwork path for cleanup.

Cleanup validates managed relative paths, limits deletion to app-owned UUID names
and counts references from tracks, albums, artists and playlists. Shared covers stay
until the final reference is removed. Arbitrary unrelated filenames are preserved.

Rows load bounded thumbnails asynchronously and use a bounded image cache. Full
player covers are also downsampled. A changed/removed path invalidates the displayed
image; missing artwork falls back to the existing music-note design. Imported
embedded artwork is validated/downsampled too; invalid embedded art does not make
otherwise valid audio unplayable. Original audio bytes and embedded tags are unchanged.

Current-track metadata/artwork is republished to system media controls without a
transport restart. Native Photos-picker interaction and actual Lock Screen rendering
remain part of physical-device acceptance.
