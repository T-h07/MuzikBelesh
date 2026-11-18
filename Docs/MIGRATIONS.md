# Database migrations

The `DatabaseManager` owns one `DatabaseMigrator`. Add new schema changes as a new migration name; never edit a migration that has shipped to a user. Fresh databases and already-migrated databases are both covered by `Phase2StorageTests`.

The live database is never deleted or recreated automatically. A migration error is surfaced as unavailable local storage and the original database remains available for recovery. Tests use an isolated temporary root so migration and repository tests cannot touch the user container.

The current sequence ends at `v013_playlist_migration_storage` (13 migrations).
`MigrationStorageSchema.register` appends it after v012 without changing released
schema definitions. The Phase 10.1 tests upgrade a real v012 database, reopen v013,
and verify existing playlist, likes, queue, history and playback state.
See [Phase 10.1 persistence](PHASE_10_01_PERSISTENCE.md).

Phase 11.5 appends `v027_dynamic_collection_artwork` after `v026_portable_library_sharing`. It creates `collection_artwork_preferences` and three delete triggers only; no existing row or table changes. `CollectionArtworkPreferenceTests` upgrades a populated v026 database. See [Phase 11.5](PHASE_11_05_DYNAMIC_ARTWORK.md).

Phase 11.4 appends `v026_portable_library_sharing` after `v025_listening_analytics`. It rebuilds `playlist_migrations` (GRDB runs migrations with foreign keys off; the migration refuses to run if enforcement is on) to widen the `source` CHECK to `muzikBelesh`, preserving every row, rowid, constraint and index, and creates three new tables. `PortableLibrarySchemaTests` upgrades a populated v025 database. See [Phase 11.4](PHASE_11_04_LIBRARY_SHARING.md).

Phase 11.2 appends `v025_listening_analytics` after `v024_local_user_profile`; it creates
new tables only and changes no existing row. See [Phase 11.2](PHASE_11_02_LISTENING_ANALYTICS.md).

Phase 11.1 appends `v024_local_user_profile` after `v022_playlist_link_downloads`.
`v023` is intentionally unused: the canceled Phase 10.8 test build applied
`v023_spotify_pending_imports` on some phones, and GRDB ignores that unknown identifier.
`LocalProfileUpgradeTests` rewinds a database to the exact v1.1.0 schema, reopens it and
checks every library table is unchanged.

## Phase 12 (v1.2.0) — no new migration

v1.2.0 adds **no** schema change; its final migration is `v027_dynamic_collection_artwork`.
The full v1.2.0 sequence is v001–v022 (as shipped in v1.1.0), then v024–v027; `v023` stays
reserved and unregistered.

`Phase12UpgradeMatrixTests` is the release gate for in-place updates. It builds one
populated library (ordered playlist, like, migrated playlist with repeated sources and
ready occurrences, profile and listening session where the cut has them), rewinds it to the
schema of v1.1.0 (v022), Phase 11.1 (v024), 11.2/11.3 (v025), 11.4 (v026) and 11.5 (v027),
reopens it with the current `StorageCoordinator` and asserts that every pre-existing row is
unchanged, `PRAGMA integrity_check` is `ok`, `PRAGMA foreign_key_check` is empty, playlist
order, profile and audio files are kept, v023 is never applied, and a second launch changes
nothing. Rewinding removes later tables and their `grdb_migrations` rows; the widened
`playlist_migrations.source` CHECK from v026 is not reverted for earlier cuts (it only
accepts more values), and the v025→v026 rebuild itself is covered by
`PortableLibrarySchemaTests`.
