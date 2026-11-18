# Install and update Muzik Belesh with SideStore

**Current stable release:** [Muzik Belesh v1.2.0](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0) — build 200, published on 18 November 2026.

Muzik Belesh is distributed as an **unsigned iOS IPA** for personal installation with SideStore. It is not an App Store download and does not contain a distribution certificate or provisioning profile.

> [!CAUTION]
> **Updating an existing installation? Do not uninstall Muzik Belesh.** Install the new IPA over the existing app using the same SideStore signing identity. Removing the app may delete the local SQLite library and downloaded audio.

## Requirements

- An iPhone running **iOS 17.0 or later**.
- SideStore configured to sign and install iOS apps with your Apple Account.
- Developer Mode/trust settings enabled if requested by iOS.
- Enough free device space for the IPA, temporary installation and your existing music.

SideStore and iOS may impose signing, entitlement, app-ID and refresh restrictions. Free Apple Accounts generally require refreshing sideloaded installations every seven days.

## Install v1.2.0

1. Open the [Muzik Belesh v1.2.0 GitHub Release](https://github.com/T-h07/MuzikBelesh/releases/tag/v1.2.0).
2. Download [`OFFLINE-unsigned.ipa`](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-unsigned.ipa).
3. Transfer the IPA to the iPhone using Files, AirDrop or another supported transfer method.
4. Open the IPA with SideStore and sign/install the **main app and embedded Share extension**.
5. If iOS requires it, enable Developer Mode and trust the newly signed installation.
6. Launch **Muzik Belesh**. Create a local profile if this is your first launch, then import audio through Files or find supported audio to download for offline use.

The canonical project identifiers are:

| Component | Identifier |
| --- | --- |
| Main app | `com.th07.muzikbelesh` |
| Share extension | `com.th07.muzikbelesh.share` |
| Requested App Group | `group.com.th07.muzikbelesh.inbox` |

SideStore may produce a signed identifier with an account-specific suffix. **Preserve the same signing setup for subsequent updates**; don't manually change the underlying project identifiers.

## Updating from v1.0.0, v1.1.0 or a Phase 11 test build

1. **Keep the existing installation on the phone.** Do not delete it.
2. If possible, keep backup copies of important personally imported audio and portable library metadata.
3. Download the **v1.2.0 IPA**, not an older Phase 12 build artifact.
4. Sign and install it **over the existing Muzik Belesh app** with the **same SideStore identity**.
5. Open the app and allow its normal database migration/initialization to finish.
6. Verify several existing songs, playlist order, albums and local artwork; also check your profile, analytics, theme, downloads and artwork preferences if you used Phase 11 builds.

Muzik Belesh's persistent library uses on-device managed audio files and SQLite migrations. The v1.2.0 update retains the established storage and bundle identities and adds the Phase 11 persistence schema. Users upgrading directly from v1.1.0 may be prompted to create their local profile once.

The project owner reported **10/10 physical release-acceptance checks passed** on an in-place installation of v1.2.0 build 200, including preservation of music, downloads and playlists. This is positive manual evidence, not proof of every possible device/signing scenario.

## Verify the IPA checksum

The release also contains:

- [`OFFLINE-build-manifest.json`](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-build-manifest.json)
- [`OFFLINE-unsigned.ipa.sha256`](https://github.com/T-h07/MuzikBelesh/releases/download/v1.2.0/OFFLINE-unsigned.ipa.sha256)

The expected SHA-256 for the official **v1.2.0 build 200** unsigned IPA is:

```text
a59f7597946dd64d3cc25cbeef675a3cf1f87f09dd0ce8e4b265b2ed73685ea2
```

**On Windows (PowerShell):**

```powershell
Get-FileHash -Algorithm SHA256 .\OFFLINE-unsigned.ipa
```

**On macOS:**

```bash
shasum -a 256 OFFLINE-unsigned.ipa
```

Compare the calculated hash with the release checksum file. It should match before you sign the IPA; SideStore's signing changes the installed binary.

The accepted app source was commit `ab3763cd0a1f9dfec628bd590d3a2627bb34118f`, packaged in [GitHub Actions run #110](https://github.com/T-h07/MuzikBelesh/actions/runs/44371763077). Use the **GitHub Release** for the stable download rather than old test artifacts.

## Common installation questions

**Why is the IPA unsigned?** GitHub Actions builds the device app without an Apple provisioning profile. SideStore supplies user-specific signing at installation.

**Will I lose music when updating?** Installing in place with compatible signing preserves the existing app container in the tested upgrade scenario. Uninstalling first can erase the music. Keep an independent backup of irreplaceable files.

**Why can't I share from YouTube and have the app open automatically?** The iOS Share extension stores validated links in the shared App Group inbox. Open Muzik Belesh manually to finish the import; automatic foregrounding is not supported by the public iOS extension API.

**Why did a background download stop?** iOS manages native background transfers. After a force-quit, saved work is reconciled when you reopen the app. Connectivity, source availability and signing refresh can also affect behavior.

**What if I have the wrong signing identity?** Do not uninstall or reset the app as a troubleshooting step. Confirm the existing SideStore identity and the ability to install over the same container before proceeding.

## Release history and further reading

- [Latest release and all previous versions](https://github.com/T-h07/MuzikBelesh/releases)
- [v1.2.0 release notes](RELEASE_NOTES_v1.2.0.md)
- [Known platform limitations](KNOWN_LIMITATIONS.md)
- [Build and packaging pipeline](BUILD_PIPELINE.md)
- [Physical-device acceptance report](PHASE_12_DEVICE_ACCEPTANCE.md)
