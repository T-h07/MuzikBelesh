# Playback Queue

Phase 4 uses `PlaybackQueueEntry` occurrences with UUID identities. A track may occur more than once. **Play Next** inserts at the front (newest first); **Add to Queue** appends. Reordering changes only positions, and removal deletes only the selected occurrence. Clear removes explicit Up Next entries while leaving the current track playing.

Explicit queue entries are consumed before the active library context. Missing or unavailable tracks are reconciled on restore and skipped during transitions. Queue mutations are persisted transactionally through GRDB.

## Imported playlist occurrences

Migration playlist contexts use `MigrationPlaybackOccurrence` (occurrence UUID plus
real local track ID). Navigation uses occurrence IDs; only the resolved real recording
is sent to audio selection. This preserves repeated local recordings in source order,
shuffle, Previous/Next and restart. `playback_state.migrationContextJSON` retains the
mapping/current occurrence atomically with the queue snapshot. Missing files are
filtered without deleting their source occurrence. Ordinary contexts keep their
existing track-ID navigation. See [Phase 10.1](PHASE_10_01_PERSISTENCE.md).
