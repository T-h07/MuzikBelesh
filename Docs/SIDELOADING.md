# SideStore installation

Physical-device testing is currently **PENDING PHYSICAL DEVICE TEST**. No iPhone installation is claimed.

1. Run **Build unsigned IPA** in GitHub Actions and download `OFFLINE-Phase0-unsigned-IPA`.
2. Transfer the IPA to the iPhone using Files, AirDrop, or the SideStore transfer method.
3. Open it in SideStore and allow SideStore to sign/install it with the personal Apple Account.
4. Enable Developer Mode in Settings when iOS requests it, and trust the developer profile if prompted.
5. Launch OFFLINE and complete `Docs/TEST_PLAN.md`.
6. For updates, download a later artifact and install it through SideStore; check whether app data remains.

Free Apple Accounts normally require a seven-day refresh cycle and have limits on simultaneously installed sideloaded apps/App IDs. Exact limits vary by iOS/SideStore behavior. A Share extension has its own App ID and may require separate signing/entitlements; Phase 0 documents packaging but does not claim SideStore signing or native handoff success.

