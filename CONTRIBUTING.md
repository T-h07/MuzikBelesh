# Contributing

OFFLINE is developed in small, reviewable phases. Phase 0 is limited to project foundation, CI, diagnostics, and feasibility probes.

`develop` is the integration branch; `release` is stable and requires explicit owner authorization. Phase work uses `feature/phase-XX-name` branches starting from `develop`; bug fixes use `fix/description`. Pull requests target `develop`. Do not create automatic releases from development branches.

Windows is supported for editing and Git. Native compilation runs on GitHub Actions macOS runners. Never commit signing certificates, provisioning profiles, credentials, IPA files, or generated Xcode projects. Keep unit tests deterministic and record incomplete physical-device checks as `NOT RUN`, `PARTIAL`, or `BLOCKED`.

