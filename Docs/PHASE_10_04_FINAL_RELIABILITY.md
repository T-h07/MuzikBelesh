# Phase 10.4 final reliability correction

## Evidence and limits

Baseline: `4c82d3f`; device report: IPA #80, HTTP 302, HTML, eight processed entries.
The baseline delegate calls `completionHandler(nil)` for unapproved redirect hosts.
Foundation then returns the original redirect response, exactly as documented by
[Apple](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).
The transport discarded Location and the provider mapped 302 to `searchUnavailable`.
Matching retried it and eventually paused after three failed occurrences. This
explains the generic diagnostic and repeated requests, **not YouTube's reason for
redirecting this particular iPhone**. Its destination was not captured in #80.

Confirmed policy defects: normal mobile-host redirects were rejected; same-host
sign-in/verification paths were allowed by the old host-only check. They are now
distinguished. One bounded anonymous desktop request with the application's
User-Agent and language headers returned HTTP 200 HTML without a redirect. No
200-request live stress test was performed. This does not reproduce the iPhone's
network, IP reputation, or upstream decision after several searches.

## Changes

- Request-local redirect delegates allow HTTPS canonical/mobile redirects within
  the same endpoint, request purpose and method. Five redirects maximum; POST
  continuation bodies are retained. Media and artwork remain isolated.
- Consent, login and verification destinations are never followed. Unsupported,
  foreign, unsafe and looped redirects pause discovery without automatic retries.
  Diagnostics carry fixed host/path categories, HTTP status and operation through
  the provider; never Location, queries, headers, bodies or arbitrary hostnames.
- Anonymous ephemeral transport retains its existing no-cookie behavior. Shared
  credential storage is explicitly disabled. No consent cookie, browser session,
  identity rotation or challenge bypass is introduced. There is no evidence that
  a different User-Agent or invented cookies would fix the reported failure.
- Track-specific watch failures remain isolated; a redirect restriction or 429
  from watch enrichment is provider-wide. Existing pacing and failure thresholds
  are unchanged. Only successful search/watch responses are cached, at most 200
  of each per run; each occurrence still has its own candidate identity and score.
- Completed empty searches are checkpointed and skipped on resume, like completed
  proposals. Failed/unfinished occurrences remain retryable; candidates survive
  cancellation, provider pause and database reopen. Requests interrupted before
  an atomic commit may need to be repeated; no exactly-once network claim is made.
- First-page JSON uses the same strict known-layout parser as embedded HTML JSON.
  Unknown schema/restriction text still fails rather than becoming “no results”.
  Watch enrichment now retains available uploader and safe artwork metadata.
- Paused UI explains the bulk anonymous-search limitation and exposes Retry
  Unfinished Discovery. Each occurrence offers browser search. Existing Resolve
  Existing Placeholder associates verified audio already in the local library.
  Browser consent does not authorize or guarantee recovery of the anonymous app
  session. No paid API, proxy service, automatic download or relaxed gate is added.

## Verification

`FinalDiscoveryReliabilityTests` adds native delegate and URLSession protocol
tests, HTTP 302/429 pipeline pauses, HTML/JSON validation, 200 duplicate occurrences,
request reuse, metadata/link/artwork persistence after reopen, and empty-result
checkpoints. `MatchingFailureIsolationTests` adds consecutive failure/recovery
over 200 entries. Existing isolation, interruption, candidate-history, scoring and
background-lifecycle tests remain in the focused workflow.

Windows SQLite/static regression checks and `git diff --check` pass.
[Native verification run 43637026236](https://github.com/T-h07/MuzikBelesh/actions/runs/43637026236)
completed successfully on 2026-11-14, testing implementation commit
`0caf86ab9edccfffc155367ea60735015a016450` with `matching_only=true`:

- macOS foundation XCTest: **14 tests, zero failures**.
- Xcode 26.2 application and all test products: **TEST BUILD SUCCEEDED**.
- iOS 26.2 simulator focused XCTest: **91 tests, zero failures**. This includes
  all eight FinalDiscoveryReliabilityTests and five MatchingFailureIsolationTests,
  plus scoring, candidate persistence, cancellation and background lifecycle suites.

The verification-note commit changes documentation only; executable sources,
tests and workflow are identical to the tested implementation. No IPA build was
triggered. Physical-iPhone recovery and uninterrupted 200-entry anonymous discovery
remain device acceptance checks, not established results. In particular, fixture
success does not establish why YouTube redirected the original iPhone or guarantee
that the anonymous provider will permit a large playlist on that network.
