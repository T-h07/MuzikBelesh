# Phase 10.2 — Offline playlist metadata import

This phase adds Files → private staging → parsing → normalization → review → Phase 10.1 persistence. It creates source placeholders, not local audio. It does not call Spotify, resolve artwork, match recordings, download audio, or upload files. No migration, playback engine, signing, bundle identifier or Share extension change is required.

## Components

| File | Responsibility |
| --- | --- |
| `OFFLINE/PlaylistMigration/Import/PlaylistImportFileAccess.swift` | Coordinated security-scoped acquisition, bounded copy, asynchronous importer and batch report assembly |
| `SpotifyPlaylistJSONParser.swift` | Account-data playlist collections and independently validated nested occurrences |
| `ExportifyCSVParser.swift` | UTF-8 RFC 4180 state machine, header mapping and artist decoding |
| `PlaylistZIPReader.swift` | Classic ZIP metadata preflight and bounded ZIPFoundation decompression |
| `PlaylistImportNormalization.swift` | Text, duration, identity and artwork validation; Phase 10.0 snapshot construction |
| `PlaylistImportReport.swift` | Limits, candidate diagnostics, deterministic identity and duplicate classification |
| `PlaylistImportCoordinator.swift` | Review lookups and approved writes through migration persistence contracts |
| `OFFLINE/Features/Library/PlaylistImportView.swift` | Files picker, review, selection, destination naming, cancellation and results |

`LibraryView.swift` adds **Import Spotify Playlist** to the existing Playlists filter. `GRDBPlaylistMigrationRepository.swift` adds session lookup, an atomic destination-name option and an in-transaction ambiguity check. `project.yml` pins ZIPFoundation 0.9.20 for the app and unit tests. New parser, ZIP, integration and UI test files use synthetic input exclusively.

## Accepted documents

Files picker UTTypes are `.json`, `.commaSeparatedText` and `.zip`. Extensions are matched without case sensitivity; document structure must agree with the selected format. A renamed arbitrary JSON file does not become a playlist. ZIP members may be nested in directories but archives are never recursively opened.

### Spotify account-data JSON

JSON documents must be UTF-8.

The accepted root is an object containing `playlists`, an array of playlist objects. Each playlist requires `name` and a complete `items` array. Each item requires a usable `track` object and `track.trackName`. An empty `items` array is valid. This synthetic minimal fixture illustrates the account-data structure:

```json
{
  "playlists": [{
    "name": "Synthetic Playlist",
    "lastModifiedDate": "2025-01-01",
    "items": [{
      "track": {
        "trackName": "Synthetic Song",
        "artistName": "Synthetic Artist",
        "albumName": "Synthetic Album",
        "trackUri": "spotify:track:0000000000000000000001"
      },
      "episode": null,
      "localTrack": null,
      "addedDate": "2025-01-01"
    }]
  }]
}
```

The field structure was checked against a published [account-data schema implementation](https://github.com/ttybitnik/diego/blob/v1.1.3/internal/app/social/spotify/playlist.go). Spotify describes the distinction between playlist data and listening history in [Understanding your data](https://support.spotify.com/sa-en/article/understanding-your-data/). No personal exports were copied into this repository.

Optional track fields: `artistName`, `albumName`, `trackUri`. Explicit compatible extensions `durationMs`, `additionalArtists` (array of names), and `artworkUrl` are accepted when present; they are not assumed to exist in every official export. Optional playlist `playlistUri` must be a Spotify playlist URI to establish trustworthy source identity. Missing fields remain nil. A supplied item `position` must equal its zero-based array index. Array order is otherwise authoritative.

Account dates, description and follower counts are recognized as surrounding account-data metadata but are not stored by the Phase 10.0 source snapshot. `msPlayed`, streaming history, Web API pagination and unrelated root structures are not treated as playlists or recording duration. Non-null `episode` / `localTrack`, missing tracks, invalid types, titles or positions reject the entire affected playlist. Other playlists in the decoded collection remain independent. Invalid document syntax or structure creates one document-level failure candidate.

### Exportify CSV

The only required column is `Track Name`. Header order is arbitrary; comparison trims header whitespace and ignores case. Duplicate headers (including normalized duplicates) are rejected. Additional columns are ignored. Header-only CSV is an empty playlist. Every subsequent logical record is an occurrence, including repeated tracks; blank records, mismatched widths and malformed quoting reject the entire playlist.

| Column | Treatment |
| --- | --- |
| `Track Name` | Required nonblank title |
| `Track URI` | Optional authentic Spotify track URI and extracted track ID |
| `Artist Name(s)` | Primary/additional artists if unambiguously encoded; otherwise original combined text |
| `Artist URI(s)` | Confirms the number and identity syntax of the artist list; not separately persisted |
| `Album Name` | Optional album text |
| `Track Duration (ms)` | Empty → nil; otherwise ASCII decimal nonnegative Int64 milliseconds |
| `Album Image URL` | Optional sanitized HTTPS metadata reference; never fetched |
| `Album URI`, `Album Artist Name(s)`, `ISRC`, `Added At` | Recognized but not persisted: Phase 10.0 has no corresponding fields; review explains this |
| Preview URLs and other columns | Not imported as audio or metadata |

The byte-state parser handles UTF-8 BOM, LF/CRLF, quoted commas, doubled quotes and quoted multiline text. Diagnostics use logical record numbers, including header record 1. Outside quoted fields, lone CR and trailing characters after closing quotes are errors. Source order is record order; no explicit position-column convention is claimed.

[Exportify's exporter](https://github.com/watsonbox/exportify/blob/master/src/components/data/TracksBaseData.ts) escapes commas inside artist names as `\,` and joins names with comma-space. Splitting is enabled only when a matching list of valid Spotify artist URIs confirms the number of artists. Otherwise the supplied combined text is retained, including ambiguous punctuation. A filename provides a whitespace-normalized, validated destination suggestion, never a Spotify ID. Renaming in review changes only the destination display name.

## Normalization and completeness

Each occurrence gets a new UUID and retains its array/record index. No set or dictionary keyed by recording ID is used. NFC text normalization and trimming of exterior whitespace do not infer titles, artists or albums. Unsupported control characters are rejected; tabs and embedded newlines remain valid text. Titles are limited to 300 characters, names to 120, artists to 50 × 300, albums to 300; all existing Phase 10.0 limits still apply. URIs must identify the expected Spotify entity with a 22-character alphanumeric identifier. Local and episode URIs are rejected, never relabeled as songs.

Invalid required metadata anywhere rejects that complete playlist. Artwork alone is optional: unsupported, non-HTTPS, credential-bearing, query-bearing, fragment-bearing or oversized references are discarded with a location-specific warning. Up to 50 warnings are shown per playlist. No URLs are dereferenced. Optional fields with invalid types are not fabricated. All accepted snapshots pass `PlaylistMigrationValidation.validate` before review and again before persistence.

## ZIP implementation and limits

Decompression uses [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20), pinned in XcodeGen. Its [consumer extraction API](https://github.com/weichsel/ZIPFoundation/blob/0.9.20/Sources/ZIPFoundation/Archive%2BReading.swift) permits bounded chunks and CRC calculation. The application implements metadata preflight, not a ZIP decompressor. ZIPFoundation's returned CRC is explicitly compared with the expected checksum.

| Resource | Maximum |
| --- | --- |
| Selected input / compressed ZIP | 20 MiB |
| Individual JSON/CSV document or archive member | 8 MiB expanded |
| Total archive expansion (including ignored files) | 32 MiB |
| Archive entries (including directories/ignored files) | 128 |
| Per-member expansion ratio | 200:1, using at least one compressed byte as denominator |
| Review | 100 candidates / 20,000 declared source occurrences |
| Playlist | 10,000 occurrences |
| CSV | 128 columns / 16 KiB per field |
| JSON structure | 64 levels / 50,000 containers / 500,000 separators |
| ZIP member path | 1,024 UTF-8 bytes |
| Copy / extraction chunks | 64 KiB / 32 KiB |

Supported ZIPs are classic, single-disk archives using stored or deflate compression, UTF-8/ASCII member names and flags 3 (data descriptor) and 11 (UTF-8) only. Both signed and unsigned classic descriptors are checked. Split archives, ZIP64, encryption, other flags/methods, self-extracting prefixes, path-override extra fields, special files and symlinks are rejected explicitly. Unicode member paths are supported directly as UTF-8; alternate filename-encoding extra fields are not supported.

Preflight checks the end record, exact central-directory bounds/count, each local header, name, size, CRC and descriptor, member ranges and supported extra-field layouts. Member paths reject absolute paths, drive/colon syntax, backslashes, traversal, empty/dot components, control characters and trailing spaces/dots. Case-folded/NFC duplicate names and file/directory prefix conflicts are rejected. Decompressed content size, total size and CRC are checked again. Nested archive extensions and ZIP magic are rejected; ignored non-playlist files still pass resource and integrity checks.

No member path is used as a filesystem destination. Members are decompressed one at a time into bounded memory and parsed into immutable snapshots. Any archive structural, safety or integrity failure aborts preparation of the entire review, even after earlier valid members were parsed. Valid ZIPs with invalid individual JSON/CSV documents preserve their valid candidates and show separate failures. Nothing is committed during extraction or parsing.

## Files access, cancellation and privacy

The importer obtains security-scoped access when granted, uses `NSFileCoordinator`, checks regular-file status and size, and copies in bounded chunks into a UUID-named directory under `Caches/Imports`. It releases the source scope before reading the private staged copy. No security-scoped URL, bookmark, private provider path or original document is persisted. Report labels contain only the selected filename and archive-relative member path.

Acquisition, format parsing and decompression run in a detached task with explicit cancellation propagation. Chunk, parser, member and occurrence loops check cancellation. The staging directory is removed in `defer` on success, error or cancellation. The existing storage startup reconciliation removes abandoned Imports directories after a crash (or an OS failure to remove a directory). No extracted member files are written. No source content is logged or transmitted. Live iCloud/third-party provider behavior and iPhone peak memory/latency still require device verification.

## Identity, review and transactions

The existing fingerprint remains unchanged. Operation IDs are `file-import-v1-<SHA256>` over the Phase 10.0 fingerprint. The source reference stores only versioned hashes: `mb-import-v1:<scope>:<context>:<content>`.

- Scope is provider + authentic playlist ID, when supplied; otherwise provider + source filename.
- Context includes scope, archive-relative member name and JSON playlist index. Standalone JSON uses an empty member namespace. Authentic IDs replace the index with zero, so renaming/reordering a standalone identified export does not change its identity.
- Content uses the existing fingerprint over ordered track metadata with a constant comparison name, plus sanitized artwork references. It excludes random occurrence UUIDs, timestamps, destination name and private paths.
- The final snapshot fingerprint also includes its source name, source ID and hashed reference. Changed retained metadata therefore creates a distinct operation, never overwrite/append/sync.

An exact operation retry returns the already committed session and retains its destination name. Same-name playlists with different contents, member paths or JSON slots are not merged. Distinct ZIP members intentionally retain separate identities, even with identical names and content. Changed content in a known context is labeled as a new, separate import before confirmation.

Without authentic IDs, identical retained content found under a *different scope* is ambiguous (for example, renaming a CSV or ZIP). Review blocks automatic import and explains why. The same check runs in the repository transaction to prevent stale-review races. Two unrelated files with identical basename, position and retained metadata cannot be distinguished: review explicitly says the context and metadata match and reuses the existing operation. Users cannot silently force an ambiguous duplicate in this phase. Reordered/repacked anonymous collections are not synchronization; changes in positional/member context must be reviewed as separate versions. File names are context, not claims about Spotify identity.

`PlaylistMetadataFileImporter` implements `PlaylistMigrationFileImporting`. Its legacy `playlists(from:)` is strict and throws if any candidate fails; `prepare(file:)` provides the richer partial-success report used by the UI. `PlaylistImportPersisting` extends the original persistence contract only with session lookup and destination naming. `PlaylistImportCoordinator` validates approved candidates and calls the Phase 10.1 atomic creator.

Destination naming happens inside the same transaction as source insertion while the original source name/fingerprint stays unchanged. Every transaction checks idempotency and ambiguity, creates one destination and all occurrences, verifies persisted contiguous positions/count/destination, then returns the canonical session. Invalid entries or SQLite failures roll back that playlist. No manual `playlist_tracks`, `StoredTrack`, candidates, local associations or download records are created.

The UI shows source filename/format, valid/invalid candidate counts, each known source count, errors, duplicate status, selection, optional destination naming and per-playlist progress/results. Corrupt CSV syntax may prevent a complete source count; this is not presented as zero entries. Invalid candidates cannot be selected. Cancellation between commits keeps completed playlists; cancellation within insertion rolls back that transaction. A completed transaction is recorded in the review even if cancellation arrives immediately afterward. Success links to the existing placeholder detail screen and the Library's database observation updates its playlist list. Metadata completion is separate from audio completion.

## Verification status and deferred work

New XCTest coverage uses actual parsers, ZIPFoundation-generated synthetic archives and isolated on-disk GRDB databases. It covers format edge cases, limits and unsafe archives; staging cleanup/cancellation; 500/1,000 ordered placeholders; repeated recording IDs; retry/conflict/ambiguity; independent ZIP commits; trigger-induced transaction rollback; restart; ordinary playlists and zero fabricated audio. No network client is part of this pipeline. UI tests cover native picker presentation/cancellation and a DEBUG-only synthetic 500-row file passed through the same staging/parser/review/persistence flow.

Implementation-session checks on Windows: Swift tree-sitter syntax parsing, XcodeGen YAML inspection and Git whitespace/scope checks. These are **not** Swift compilation or XCTest execution. Xcode, the iOS SDK and a simulator are unavailable here; the 500/1,000-entry tests and UI tests are **written but not executed in this session**. No GitHub Actions dispatch, polling, rerun, PR creation or merge is part of this phase's delivery. CI and device acceptance must be performed separately after the branch is pushed.

Deferred: new source schemas/localized CSV headers, ZIP64/other archive encodings, ambiguous-import reconciliation, authenticated Spotify API support, matching/scoring, audio acquisition, background transfers, synchronization, notifications and advanced review. No Phase 10.3 functionality is introduced.
