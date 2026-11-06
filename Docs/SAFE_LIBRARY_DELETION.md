# Safe library deletion

Three separate actions exist: Remove from Playlist, Unlike Song, and Delete Song
(or Remove Missing Entry). Only the last removes a track row and its managed audio.
Permanent deletion always requires an explicit dialog confirming the effect on local
audio, playlist membership, likes and queue references. Cancel performs no mutation.

On confirmation the audio command gate marks the track unavailable for new selection.
If it is current, the player stops, releases its item and clears system metadata.
Other valid queue occurrences and the Sleep Timer deadline are retained. Failure to
obtain the gate prevents filesystem deletion.

Filesystem and SQLite are not one atomic transaction. The deletion service:

1. Resolves the stored identity/path through managed containment checks and inspects
   sharing references. An audio path still used by another row is preserved.
2. Writes a prepared operation with original/staged paths to SQLite.
3. Moves the sole managed audio copy to UUID-named Application Support/DeletionStaging.
4. In one SQLite transaction rechecks identity, cleans playback JSON snapshots,
   deletes the track (foreign-key cascade/nullification) and normalizes positions.
5. Marks the journal committed in that transaction, then removes staged bytes and
   safely unreferenced artwork, and finally removes the journal.

Before-commit failures roll back database changes and restore the original file.
If restoration fails, the recovery file and journal are retained. After-commit cleanup
failure reports removal with cleanup pending; next recovery finalizes it. Startup
restores prepared operations with a surviving track before missing-file reconciliation,
and finalizes committed operations whose track is gone. Conflicting different original
and staged files are both retained for diagnosis, never silently overwritten.

Track removal cascades playlist memberships, likes, queue occurrences, listening
history and source records. Download-job track references and current playback IDs
are nullified. Context/history/shuffle JSON arrays are filtered with cursor adjustment;
valid queue occurrences remain. The application reconciles its live navigator after
the database operation. A failed attempt to delete the current song leaves playback
stopped; the preserved row can be selected again after recovery.

Missing files are marked unavailable without deleting metadata. Rows cannot start
playback while missing/modified; valid queue items continue. Remove Missing Entry
requires the same confirmation and reference cleanup. Paths or symlinks escaping
managed roots are rejected. Reconciliation never scans arbitrary external storage.

All destructive tests use UUID temporary roots and dedicated synthetic files.
Physical deletion and SideStore update remain acceptance checks, not inferred from CI.
