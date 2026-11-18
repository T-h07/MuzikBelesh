# Phase 12 — release checklist and gate matrix (v1.2.0)

A gate passes only with evidence (a run link, a measurement or a reported observation).
A gate with unknown status is **not** passed.

## Release candidate

| Field | Value |
| --- | --- |
| Version / build | 1.2.0 / 200 |
| Source SHA | FINAL_SOURCE_SHA |
| CI run | FINAL_CI_RUN |
| IPA build run / artifact | FINAL_IPA_RUN |
| IPA SHA-256 | FINAL_IPA_SHA |
| Signing | Unsigned; SideStore signs with the user's identity |

Preliminary (not for distribution): source 28603dd, run
[44301640542](https://github.com/T-h07/MuzikBelesh/actions/runs/44301640542), SHA-256
`ac3810000dff7c9f8a678ddfb9f8886d4a6562203312c3106664c950341cf433`. It predates the
upgrade-matrix and documentation commits and is superseded by the candidate above.

## Gate matrix

GATE_TABLE

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
