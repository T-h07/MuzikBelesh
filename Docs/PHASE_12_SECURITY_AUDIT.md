# Phase 12 — security, privacy and dependency audit (v1.2.0)

Scope: the v1.2.0 app (`com.th07.muzikbelesh`), its Share extension
(`com.th07.muzikbelesh.share`), the App Group `group.com.th07.muzikbelesh.inbox`, the
packaging script and the GitHub Actions workflows, at `develop` 78c5c62 plus the Phase 12
branch `feature/phase-12-final-release`.

Method: source review of every network, file, archive, database, extension and logging
boundary; targeted automated tests for each corrected finding; workflow review. No
penetration testing or fuzzing on a device was performed.

Severity: **Critical** (remote code execution or library loss), **High** (exploitable
data exposure or destructive behaviour), **Medium** (resource exhaustion or
integrity weakness that needs an unusual but realistic precondition), **Low** (hardening
with no demonstrated exploit), **Info** (verified as already correct).

## Result

| Severity | Open | Fixed in Phase 12 | Accepted residual |
| --- | --- | --- | --- |
| Critical | 0 | 0 | 0 |
| High | 0 | 0 | 0 |
| Medium | 0 | 1 (S01) | 0 |
| Low | 0 | 2 (S02, S03) | 2 (S10, S11) |

**No unresolved Critical or High finding. Gate G07: PASS. Gate G08: PASS** (see §Privacy).

## Findings

### S01 — HTTP metadata responses were buffered without a size limit (Medium, fixed)

- **Component:** `OFFLINE/YouTube/YouTubeTransport.swift` (`YouTubeURLSessionTransport`),
  `OFFLINE/PlaylistMigration/Matching/SearXNGDiscovery.swift` (`SearXNGURLSessionTransport`,
  also used by the Invidious pool).
- **Observed:** both transports used `URLSession.data(for:)`, which reads the whole body
  into memory before any check can run. SearXNG and Invidious endpoints are user-configured
  or third-party; a misconfigured or hostile server (or a captive portal) could return an
  arbitrarily large or never-ending body.
- **Risk:** memory pressure and possible termination by iOS during discovery, which can
  interrupt playback. No data loss.
- **Correction:** new `BoundedHTTPBody.read` rejects a declared `Content-Length` above the
  limit before reading, then streams with `URLSession.bytes(for:delegate:)` and cancels the
  task as soon as the limit is exceeded. Limits: 8 MB for YouTube metadata (largest
  legitimate watch-page responses are well below this), 4 MB for SearXNG/Invidious JSON.
  Oversize maps to the existing "search unavailable" / bad-response errors, and a numeric
  `transportSize` diagnostic is recorded.
- **Tests:** `Tests/Unit/Security/BoundedHTTPBodyTests.swift` — declared oversize rejected,
  streamed oversize (no Content-Length) rejected, exact-limit and small bodies intact,
  YouTube transport maps oversize to `.searchUnavailable`, discovery limit pinned.

### S02 — GitHub Actions referenced by mutable tags (Low, fixed)

- **Component:** `.github/workflows/ci.yml`, `build-ipa.yml`, `playlist-migration.yml`.
- **Observed:** `actions/checkout@v4`, `upload-artifact@v4`, `download-artifact@v4`.
  A moved tag would run different code with `contents: write` in the release pipeline.
- **Correction:** pinned to full commit SHAs (checkout v4.4.0 `11d5960a…`,
  upload-artifact v4.6.2 `ea165f8d…`, download-artifact v4.3.0 `d3f86a10…`) with the
  version in a comment. The new `publish-v1.2.0.yml` uses the same pins.
  `publish-v1.1.0.yml` is intentionally unchanged (historical, owner-gated, already used).
- **Evidence:** all workflows parse; `Scripts/check-test-hygiene.py` passes.

### S03 — Release packaging verified too little of the final bundle (Low, fixed)

- **Component:** `Scripts/package-ipa.sh`.
- **Observed:** the packager checked the app bundle ID and build provenance but not the
  extension's identity, the declared version, the minimum OS, ATS policy or the absence of
  every DEBUG-only test hook.
- **Correction:** the packager now reads the single version source (`MARKETING_VERSION` in
  `project.yml`) and asserts, for both bundles, version, matching numeric build,
  bundle IDs, `MinimumOSVersion` 17.0, the `.mbelesh` type declarations, ATS exactly
  `{NSAllowsArbitraryLoads: false, NSAllowsLocalNetworking: true}`, the App Group
  entitlement metadata, and that none of the UI-testing launch arguments or fixture
  strings are present in either Release binary. The manifest records source SHA, embedded
  commit, package pins and the IPA SHA-256, and a `.sha256` file is published.
- **Evidence:** the build-IPA workflow on the branch (see the release checklist, G14).

### Verified as correct (Info)

| ID | Boundary | Evidence |
| --- | --- | --- |
| S04 | **Spotify ZIP import**: 20 MiB input, member-count, per-entry and 32 MiB total expanded limits, compression-ratio limit, absolute/traversal/ambiguous paths rejected, symlinks and special files rejected, decompression checked against declared size and CRC | `PlaylistZIPReader.swift`; tests under `Tests/Unit/PlaylistMigration` |
| S05 | **`.mbelesh` documents** (JSON): regular files only, 32 MB bound enforced while reading, duplicate JSON keys and duplicate identifiers rejected, strict format/version/feature envelope, bounded strings and counts, YouTube video IDs validated and unknown providers ignored (never contacted) | `PortableLibraryImporter.swift`, `PortableLibraryValidation.swift`; `Tests/Unit/LibrarySharing` |
| S06 | **Share extension / App Group inbox**: only validated YouTube links are stored; the extension imports only UIKit/UniformTypeIdentifiers, makes no network requests and cannot read the library database; inbox decoding tolerates downgrade | `ShareURLValidationTests.swift`, `SharedLinkInboxTests.swift` |
| S07 | **Downloaded audio**: completed files are validated (size, type, playable) before being moved into the library; temporary files removed on failure | `TransferService.swift`, `DownloadTests.swift` |
| S08 | **SQL**: all queries use bound arguments; table names in dynamic SQL are internal constants | GRDB repositories |
| S09 | **ATS**: arbitrary loads disabled; only local networking allowed (for a LAN SearXNG) | Info.plist, now enforced by `package-ipa.sh` |

### Accepted residuals

| ID | Severity | Description | Reason accepted |
| --- | --- | --- | --- |
| S10 | Low | YouTubeKit performs its own stream-extraction requests internally; their response sizes are bounded by the library, not by `BoundedHTTPBody`. | Third-party library internals; requests go only to YouTube hosts over HTTPS. Pinned at 0.4.10. |
| S11 | Low | Background `URLSession` follows redirects under iOS control; each hop cannot be inspected before contact. | Platform behaviour; sources are validated when prepared and the result validated on completion (KNOWN_LIMITATIONS). |

## Privacy (G08)

| Data | Where it lives | Leaves the device? |
| --- | --- | --- |
| Profile name and photo | App container database / files | Never. Not in `.mbelesh` exports, diagnostics or logs. |
| Listening sessions and daily totals | App container database | Never. Not exported. |
| Theme and artwork preferences | UserDefaults / database | Never. Not exported. |
| `.mbelesh` export | User-chosen destination | Only when the user shares it: song metadata, playlist order and public YouTube IDs. No audio, file paths, profile, history or settings. |
| Diagnostics / logs | Local | Counters, durations and error categories only; no titles, names, URLs or paths. |

The exporter builds its document only from library, playlist and accepted-recording
tables (`PortableLibraryExporter.swift`); `PortableLibraryExportTests` seeds a private
profile marker and asserts that it, file paths and profile/listening/settings field names
are absent from the exported bytes. No analytics SDK, crash reporter or remote logging exists.

## Dependency audit

| Package | Pin | Notes |
| --- | --- | --- |
| GRDB.swift | 7.11.1 (exact) | SQLite access; no known advisories affecting this use. |
| YouTubeKit | 0.4.10 (exact) | Stream extraction; S10. |
| ZIPFoundation | 0.9.20 (exact) | Wrapped by bounded readers (S04). |

All three are resolved from `Package.resolved` and recorded in the IPA manifest. No
dependency was upgraded in Phase 12: an upgrade close to release has no demonstrated
benefit for v1.2.0 and would invalidate prior acceptance.

## CI and supply chain

- Actions pinned to SHAs (S02); workflows declare least-privilege `permissions`.
- `publish-v1.2.0.yml` cannot run until the owner records the accepted build, source SHA,
  IPA SHA-256 and run ID; it runs only on `main`, requires a typed SHA-256 confirmation,
  refuses if app source or packaging changed after acceptance, never moves an existing tag
  and verifies the published bytes after upload.
- The IPA is unsigned and contains no provisioning profile or `_CodeSignature`; both are
  asserted by the packager and the publisher.
