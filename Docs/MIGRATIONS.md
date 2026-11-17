# Database migrations

The `DatabaseManager` owns one `DatabaseMigrator`. Add new schema changes as a new migration name; never edit a migration that has shipped to a user. Fresh databases and already-migrated databases are both covered by `Phase2StorageTests`.

The live database is never deleted or recreated automatically. A migration error is surfaced as unavailable local storage and the original database remains available for recovery. Tests use an isolated temporary root so migration and repository tests cannot touch the user container.

The current sequence ends at `v013_playlist_migration_storage` (13 migrations).
`MigrationStorageSchema.register` appends it after v012 without changing released
schema definitions. The Phase 10.1 tests upgrade a real v012 database, reopen v013,
and verify existing playlist, likes, queue, history and playback state.
See [Phase 10.1 persistence](PHASE_10_01_PERSISTENCE.md).
