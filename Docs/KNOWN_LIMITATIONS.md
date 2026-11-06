# Known v1.0 candidate limitations

- Sharing saves a validated link in the App Group inbox. iOS does not provide a supported Share extension API to launch the containing app. Open Muzik Belesh manually to finish the handoff; no hidden responder-chain/private URL launch is used.
- YouTube formats, availability, region restrictions and extraction compatibility can change externally. Search/resolution failures show errors; deterministic fixtures do not prove current live availability.
- iOS owns background download timing. User force-quit stops background transfers until the app is manually reopened; restoration then reconciles jobs. A transfer completion does not guarantee immediate library import while the app is suspended.
- Native background URLSession follows redirects under iOS control. Phase 7.1's accepted native-transfer policy validates prepared and completed source information but cannot reject each redirect before contact. No arbitrary URL download endpoint is exposed.
- The IPA is built without an Apple identity/provisioning profile. Ad-hoc entitlement metadata declares the same App Group on the app and extension for SideStore re-signing. The sideloader must preserve compatible app/extension identities, group access and update continuity. This metadata alone does not authorize installation.
- Recent playback navigation retains 1,000 entries. Separate stored listening history is preserved. Position checkpoints are five seconds apart; an abrupt process kill can lose the most recent few seconds, while normal pause/background transitions persist.
- Serious/critical thermal state defers new work; already active native transfers are allowed to finish under OS control. Low Power Mode lowers effective concurrency without changing the user's saved preference.
- Exports need temporary storage for one verified copy. Insufficient space produces an error, leaving original music intact.
- Physical background, radio, VoiceOver, energy, thermal and in-place upgrade acceptance is pending for this candidate. Simulator performance measurements must not be presented as battery/temperature measurements.
