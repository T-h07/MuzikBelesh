# Feasibility results

No macOS runner or physical iPhone was available during repository authoring, so no success is inferred from source inspection.

| Experiment | Build result | Device result | Status | Evidence |
|---|---|---|---|---|
| SwiftUI compilation | Not run locally | Pending | NOT RUN | CI workflow added |
| Unsigned IPA packaging | Not run locally | Pending | NOT RUN | `Scripts/package-ipa.sh` |
| SideStore installation | N/A | Pending | NOT RUN | `Docs/SIDELOADING.md` |
| YouTubeKit metadata | Probe source added | Pending | NOT RUN | `YouTubeProbe.swift` |
| Audio-only extraction | Probe source added | Pending | NOT RUN | `YouTubeProbe.swift` |
| Share-extension compilation | Not run locally | Pending | NOT RUN | extension target |
| Share-extension IPA embedding | Not run locally | Pending | NOT RUN | IPA script validation |
| Share-sheet appearance | N/A | Pending | NOT RUN | device checklist |
| URL receipt | Source added | Pending | NOT RUN | `SharedURLHandler.swift` |
| Main-app handoff | Not implemented | Pending | BLOCKED | Requires supported signing/handoff experiment |

The probe forces YouTubeKit's local method and has no remote fallback. It is not evidence of live extraction until a real iPhone test is recorded.

