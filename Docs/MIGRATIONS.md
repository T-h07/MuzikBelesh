# Database migrations

The `DatabaseManager` owns one `DatabaseMigrator`. Add new schema changes as a new migration name; never edit a migration that has shipped to a user. Fresh databases and already-migrated databases are both covered by `Phase2StorageTests`.

The live database is never deleted or recreated automatically. A migration error is surfaced as unavailable local storage and the original database remains available for recovery. Tests use an isolated temporary root so migration and repository tests cannot touch the user container.

The current sequence ends at `v013_playlist_migration_storage` (13 migrations).
`MigrationStorageSchema.register` appends it after v012 without changing released
schema definitions. The Phase 10.1 tests upgrade a real v012 database, reopen v013,
and verify existing playlist, likes, queue, history and playback state.
See [Phase 10.1 persistence](PHASE_10_01_PERSISTENCE.md).

Phase 11.2 appends `v025_listening_analytics` after `v024_local_user_profile`; it creates
new tables only and changes no existing row. See [Phase 11.2](PHASE_11_02_LISTENING_ANALYTICS.md).

Phase 11.1 appends `v024_local_user_profile` after `v022_playlist_link_downloads`.
`v023` is intentionally unused: the canceled Phase 10.8 test build applied
`v023_spotify_pending_imports` on some phones, and GRDB ignores that unknown identifier.
`LocalProfileUpgradeTests` rewinds a database to the exact v1.1.0 schema, reopens it and
checks every library table is unchanged.
