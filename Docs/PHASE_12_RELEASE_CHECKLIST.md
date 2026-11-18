# Phase 12 — release checklist and gate matrix (v1.2.0)

A gate passes only with evidence (a run link, a measurement or a reported observation).
A gate with unknown status is **not** passed.

## Release candidate

| Field | Value |
| --- | --- |
| Version / build | 1.2.0 / 200 |
| Source SHA | ab3763cd0a1f9dfec628bd590d3a2627bb34118f |
| CI run | [#307](https://github.com/T-h07/MuzikBelesh/actions/runs/44371494404) — intentionally cancelled; previous runs failed |
| IPA build run / artifact | [#110](https://github.com/T-h07/MuzikBelesh/actions/runs/44371763077) — SUCCESS; artifact `OFFLINE-unsigned-IPA` (14461626413) |
| IPA SHA-256 | `a59f7597946dd64d3cc25cbeef675a3cf1f87f09dd0ce8e4b265b2ed73685ea2` |
| Signing | Unsigned; SideStore signs with the user's identity |

Preliminary (not for distribution): source 28603dd, run
[44301640542](https://github.com/T-h07/MuzikBelesh/actions/runs/44301640542), SHA-256
`ac3810000dff7c9f8a678ddfb9f8886d4a6562203312c3106664c950341cf433`. It predates the
upgrade-matrix and documentation commits and is superseded by the candidate above.

## Gate matrix

| Gate | Actual verified status | Evidence / limitation |
| --- | --- | --- |
| G01 Compilation | **PASS** | Unsigned Release IPA workflow #110 compiled app and extension successfully |
| G02 Static checks | **PARTIAL PASS** | PR CI #307 static-checks passed; complete workflow cancelled |
| G03 Unit tests | **INCOMPLETE — accepted risk** | Prior Phase 12 CI runs failed, final CI cancelled |
| G04 Integration tests | **INCOMPLETE — accepted risk** | Final full suite not completed |
| G05 UI tests | **INCOMPLETE — accepted risk** | Final regression CI cancelled; 10 developer-reported physical smoke tests passed |
| G06 Data integrity | **PHYSICAL SMOKE PASS / FULL MATRIX INCOMPLETE** | T02 and T10 pass on the iPhone; full automated coverage not confirmed |
| G07 Security | **PARTIAL / risk accepted** | Phase 12 security audit exists; not claiming complete green security verification |
| G08 Privacy | **PARTIAL / risk accepted** | No new reported issue in 10 physical tests; privacy fixture tests not reverified on final SHA |
| G09 Playback | **PHYSICAL SMOKE PASS** | T03 and T04 |
| G10 Downloads/migration | **PHYSICAL SMOKE PASS** | T05 and T06; migration CI cancelled |
| G11 Performance | **PHYSICAL SMOKE PASS / METRICS UNVERIFIED** | User reports functioning UI; no final device-level benchmarks claimed |
| G12 Memory | **NOT FULLY VERIFIED** | No physical long-duration memory profile reported |
| G13 Artwork | **PHYSICAL SMOKE PASS** | T09 including rotation and custom priority |
| G14 IPA packaging | **PASS** | Build #110, version 1.2.0, build 200, source ab3763c, SHA-256 above |
| G15 In-place update | **PHYSICAL SMOKE PASS** | T02 and T10 preserved data |
| G16 Developer physical acceptance | **EXPEDITED 10/10 PASS** | T01–T10 in PHASE_12_DEVICE_ACCEPTANCE.md; detailed R01–R45 not individually executed |
| G17 Owner publication approval | **APPROVED** | Owner explicitly approved release despite the disclosed incomplete CI on 2026-11-18; publication workflow has separate explicit manual authorization |


## Pre-publication checklist (owner)

1. Install the candidate above over the existing app with SideStore; do not uninstall.
2. Run R01–R45 in [PHASE_12_DEVICE_ACCEPTANCE.md](PHASE_12_DEVICE_ACCEPTANCE.md) and
   report results with the build number and SHA-256.
3. Approve merging `feature/phase-12-final-release` → `develop`, then the reviewed
   release integration into `release` and `main` (no force-push, no history rewrite).
4. Confirm the app source on `main` is identical to the accepted source (the publisher
   refuses otherwise); if it differs, rebuild, re-verify and repeat affected cases.
5. Record `ACCEPTED_BUILD`, `APPROVED_SOURCE_SHA`, `ACCEPTED_IPA_SHA256` and
   `ACCEPTED_RUN_ID` in `publish-v1.2.0.yml` in a reviewed commit.
6. Run **Publish Muzik Belesh v1.2.0** from `main`, ticking the approval box and typing
   the accepted SHA-256.
7. Verify the GitHub Release lists `OFFLINE-unsigned.ipa`, `OFFLINE-build-manifest.json`
   and `OFFLINE-unsigned.ipa.sha256` with the accepted hash, and that tag `v1.2.0`
   points at the published `main` commit.

`v1.1.0` artifacts, tag and workflow are never modified.

## Accepted expedited publication decision — 2026-11-18

The owner expressly approved merging and publishing v1.2.0 **with the documented remaining CI limitations** after reporting **10/10 PASS** for the expedited iPhone acceptance. [PR #30](https://github.com/T-h07/MuzikBelesh/pull/30) merged to `develop`, [PR #31](https://github.com/T-h07/MuzikBelesh/pull/31) integrated into `release`, and [PR #32](https://github.com/T-h07/MuzikBelesh/pull/32) integrated into `main`. All changes relative to the accepted source `ab3763c` in the stable branch at verification were documentation or the publication workflow; no `OFFLINE/`, `OFFLINEShareExtension/`, `Sharing/`, `project.yml` or `Scripts/package-ipa.sh` changes.

The manual publisher on `main` is pinned to IPA build 200 from run 44371763077, exact accepted source and SHA-256 above. **Approval and preparation are not evidence of actual publication**; the workflow's run and published release asset checks are required to mark publication successful.
