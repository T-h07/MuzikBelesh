# v1.0.0 candidate release checklist

Integration branch: feature/phase-09-release, based on accepted Phase 8 merge b9386122a56ddf1550b360c4ce9401ff100ceeb3. Open an integration PR targeting develop; leave it unmerged. Keep release at 1276c9cdd44742a837eed6f4305d26f571085dc2 until explicit publication approval. No stable tag or published Release is authorized.

## Gates

| Gate | Required evidence | Candidate status |
|---|---|---|
| A Features | All F01–F15 complete, production screens usable, feature matrix and full regressions | PARTIAL; physical matrix pending |
| B Reliability | No unresolved P0/P1; route/reset, queue, imports, recovery and stress pass | PARTIAL; automated results in PR, hardware pending |
| C Data | Historical migrations, duplicates, rollback, missing-file recovery; build 189 in-place library preserved | PARTIAL; P0,P1,P14,P19 pending |
| D Performance | Baseline/optimized work counts, search/SQLite/memory tests, no severe avoidable regression | PARTIAL; device energy/memory evidence pending |
| E Thermal | Normal-use comparison, no repeatable app-induced serious heat; LPM/resource policies | NOT RUN on device |
| F Network | Wi-Fi-only, authorized cellular, offline/recovery, background restoration | NOT RUN on device |
| G Accessibility | Compact/standard/large simulator checks plus physical VoiceOver/large text | PARTIAL; P18 pending |
| H Sharing | YouTube and Safari post-upgrade handoff | NOT RUN on candidate device |
| I Artifact | Exact SHA, 1.0.0 and monotonic build in both executables, arm64/min OS/icons/audio mode/App Group, checksum/readback | Pending final workflow and independent artifact verification in PR |
| J Acceptance | User explicitly confirms required P0–P24 results | NOT RUN |
| K Publication | User explicitly approves release merge, stable tag and GitHub Release | BLOCKED; not authorized |

## Efficient verification and artifact record

1. Baseline profile, then coherent implementation and local static checks.
2. One focused workflow; investigate any failure before retry. Do not launch overlapping builds.
3. Complete verification reuses focused products only when product-source.txt matches exact HEAD. Compact, standard-accessibility and full suites precede a fresh Release device build.
4. Save run URL, source SHA, version/build, IPA SHA-256, manifest and both entitlement readbacks in the integration PR. Test Debug product build number may differ from final Release artifact because separate workflow run numbers are monotonic.
5. Update build 189 in place via the same signing identity; record device acceptance against the delivered candidate checksum.
6. If implementation changes after acceptance, rerun affected checks and get acceptance of the new IPA. Do not silently relabel an old binary.

CI evidence is authoritative for execution counts; these source documents deliberately do not mark a future run passed. Physical statuses start NOT RUN and must be changed only with actual observations.

## Prepared release notes (draft, unpublished)

Muzik Belesh 1.0.0 brings the persistent local library, background and Lock Screen playback, AirPods controls, shuffle/repeat/seek, playlists/likes/albums, editable metadata/artwork, local search/sorting, duplicate-safe Files import/export, YouTube search and quality-aware queued downloads, Wi-Fi policy and native shared-link inbox.

This candidate reduces periodic playback database work, removes quadratic navigation setup, caches Now Playing artwork, uses file-based export, and adds thermal/Low Power scheduling. Route-loss handling covers waiting audio; media-services reset rebuilds playback paused for explicit user resume. The original audio bytes remain unchanged. See KNOWN_LIMITATIONS for manual Share handoff, platform-dependent YouTube behavior and force-quit constraints.

Upgrade: install over build 189 using the existing SideStore identity and matching group configuration. Do not uninstall. Compare library counts, edits, playlists, likes, queue and representative audio before/after; stop and record any discrepancy.

## Publication procedure — approval required

After every gate is accepted, record explicit user authorization, merge the reviewed integration PR into develop, perform the approved develop-to-release integration, and tag the approved release commit v1.0.0. Publish a GitHub Release with the verified IPA, manifest, checksums and final notes. If a merge changes executable source, rebuild/verify and retest before publication. Check remote branches/tag and release visibility afterwards. None of these publication steps is performed by Phase 9 preparation alone.
