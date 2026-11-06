# Storage recovery

Import operations record staging state in `import_operations`. On startup, interrupted download-job records are changed to `interrupted`, incomplete staging files are removed, and every track's relative file is reconciled. A missing file changes availability to `missing` without deleting metadata or recreating the database.

The database is the source of truth for relationships and metadata; managed files are the source of truth for bytes. No recovery path silently invents a playable file. The UI can report unavailable storage and missing tracks for a later retry or reimport flow.

## Phase 7 downloads

Phase 7 preserves managed jobs and complete staging files across launch. Interrupted workers reconcile provenance and staging before restarting. Download staging lives separately from import staging. See PHASE_07_DOWNLOADS.md for the restart policy.
