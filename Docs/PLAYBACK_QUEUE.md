# Playback Queue

Phase 4 uses `PlaybackQueueEntry` occurrences with UUID identities. A track may occur more than once. **Play Next** inserts at the front (newest first); **Add to Queue** appends. Reordering changes only positions, and removal deletes only the selected occurrence. Clear removes explicit Up Next entries while leaving the current track playing.

Explicit queue entries are consumed before the active library context. Missing or unavailable tracks are reconciled on restore and skipped during transitions. Queue mutations are persisted transactionally through GRDB.
