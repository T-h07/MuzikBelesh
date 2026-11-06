# SideStore installation

SideStore installation was successfully completed on the developer's iPhone on November 2, 2026. The app launched into the native diagnostics screen. This is manual evidence, separate from automated CI.

1. Run **Build unsigned IPA** in GitHub Actions and download `OFFLINE-unsigned-IPA`.
2. Transfer the IPA to the iPhone using Files, AirDrop, or the SideStore transfer method.
3. Open it in SideStore and allow SideStore to sign/install it with the personal Apple Account.
4. Enable Developer Mode in Settings when iOS requests it, and trust the developer profile if prompted.
5. Launch Muzik Belesh and complete `Docs/TEST_PLAN.md`.
6. For updates, download a later artifact and install it through SideStore; check whether app data remains.

The installed bundle identifier included a SideStore-generated suffix; this is expected signing behavior and does not change the canonical project identifier `com.th07.muzikbelesh`. Free Apple Accounts normally require a seven-day refresh cycle and have limits on simultaneously installed sideloaded apps/App IDs. Exact limits vary by iOS/SideStore behavior. A Share extension has its own App ID and may require separate signing/entitlements. Phase 0 verified appearance and URL receipt, while automatic handoff remains deferred to Phase 8.

The Phase 3 final unsigned IPA is accepted for in-place SideStore testing by developer-reported iPhone 13 Pro Max validation. Preserve the existing bundle identity and app container so imported music and SQLite data remain available. iOS may cache app icons after updates; verify the icon after installation.

# Phase 4 IPA note

The unsigned IPA workflow remains unchanged for SideStore. The Phase 4 package must retain `Assets.car`, the app icon resources, and `PlugIns/OFFLINEShareExtension.appex`; timer and queue state are application data and are not packaged into the IPA.


# Phase 5 in-place update

Use the IPA and manifest linked in the Phase 5 PR, from the same source as its final
passing CI. Verify version/build/embedded commit before testing. Packaging validates
app/extension metadata, canonical bundle IDs, assets, background audio and source SHA.
Keep the existing SideStore identity/container. v009 adds library metadata/search,
context and recovery fields without resetting v001-v008 data. Existing audio bytes
and paths do not change merely because metadata is edited.

Physical migration/update and all PHASE_05_DEVICE_TESTING.md cases are still NOT RUN
until the developer records results. Do not infer them from an unsigned build or
synthetic migration tests. No production GitHub Release or stable tag is published.

## Phase 9 upgrade from accepted build 189

Install the 1.0.0 candidate over the existing app with the same SideStore identity.
Do not uninstall or change bundle IDs/App Group. Both app and extension must be
re-signed; ad-hoc entitlement metadata remains embedded so the signer can request
`group.com.th07.muzikbelesh.inbox`. No Apple provisioning profile or trusted
identity is supplied by the unsigned artifact.

Before updating, record library counts, playlists, likes, edited metadata/artwork,
queue and a few exported audio hashes. Compare after update using
PHASE_09_DEVICE_TESTING.md P0/P1/P24, then repeat YouTube and Safari share with
manual app opening. A signed install and passing simulator are insufficient to
claim data-preserving device acceptance. Record the exact IPA checksum and build.
