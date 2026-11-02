# SideStore installation

SideStore installation was successfully completed on the developer's iPhone on November 2, 2026. The app launched into the native diagnostics screen. This is manual evidence, separate from automated CI.

1. Run **Build unsigned IPA** in GitHub Actions and download `OFFLINE-unsigned-IPA`.
2. Transfer the IPA to the iPhone using Files, AirDrop, or the SideStore transfer method.
3. Open it in SideStore and allow SideStore to sign/install it with the personal Apple Account.
4. Enable Developer Mode in Settings when iOS requests it, and trust the developer profile if prompted.
5. Launch Muzik Belesh and complete `Docs/TEST_PLAN.md`.
6. For updates, download a later artifact and install it through SideStore; check whether app data remains.

The installed bundle identifier included a SideStore-generated suffix; this is expected signing behavior and does not change the canonical project identifier `com.th07.muzikbelesh`. Free Apple Accounts normally require a seven-day refresh cycle and have limits on simultaneously installed sideloaded apps/App IDs. Exact limits vary by iOS/SideStore behavior. A Share extension has its own App ID and may require separate signing/entitlements. Phase 0 verified appearance and URL receipt, while automatic handoff remains deferred to Phase 8.

