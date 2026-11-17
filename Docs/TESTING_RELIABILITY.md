# Testing reliability guide

How Muzik Belesh's automated tests are organised, how to read a red CI run, and the
rules that keep UI tests trustworthy. Written after Phase 10.4, where most CI failures
were test-architecture problems rather than app bugs.

## Verification tiers

| Tier | Where | What | Cost |
|---|---|---|---|
| A: fast | `ci.yml` → `static-checks` (Linux), also first step of the migration workflow | `Scripts/check-test-hygiene.py`, `Scripts/verify-matching-corrections.py` | seconds |
| B: feature | `playlist-migration.yml` (every PR to `develop`; `matching_only` for unit-only) | foundation persistence, all matching/review/import unit suites, migration + review-queue + file-import UI | ~25 min |
| C: complete | `ci.yml` → four `regression-*` shards + `build-and-test` gate | every deterministic unit test, library UI, other UI, compact iPhone, accessibility | ~40 min per shard, parallel |

The simulator shards don't start until tier A passes. A merge needs B and C green on
the **same** commit SHA. Each job checks that it tested the PR head commit and writes
that SHA to the run summary.

## Result integrity

Every `xcodebuild` test step is followed by `Scripts/check-test-results.py`, which reads
the `.xcresult` (not the log) and fails when:

- a required suite ran zero test cases (a typo in `-only-testing`, a runner restart).
  Requirements are suite names, or derived from the sources: `--expect-suites-in
  Tests/Unit:OFFLINETests` requires every test class declared there. There are no
  global count floors to maintain when tests are added or removed,
- any test was skipped (opt-in `YouTubeLiveTests` is excluded explicitly instead),
- a test has no final result, or Xcode's overall result isn't `Passed`.

"Executed 0 tests" after `Restarting after unexpected exit, crash, or test timeout` is
never a pass.

`Scripts/check-test-hygiene.py` also fails when a workflow names a class or method that
doesn't exist, or when a `Tests/Unit/PlaylistMigration` suite is missing from the
feature workflow.

## When CI fails

1. **Identify:** the exact test, file:line, assertion, shard and step. `gh run view <id> --log-failed`,
   then the full log for the timeline (`t = …s` lines).
2. **Classify:** production bug, outdated expectation, fixture, XCUITest interaction,
   simulator quiescence, timeout, workflow config, or runner instability. Gather evidence:
   did the same test pass at another commit? Where did the time go?
3. **Reproduce:** with the smallest suite that shows it (`-only-testing:Bundle/Suite/test`).
4. **Fix the root cause:** the smallest correct change. If it's an intended UX change,
   update the assertion to the new contract; never change the app to fit an old test.
5. **Check locally:** run the static checks above (they work on Windows/Linux too).
6. **Verify in CI:** the migration workflow first (tier B), then the complete regression.
7. **Accept:** all merge-blocking checks are green on one SHA.

Collect *every* failure from a run before pushing. One commit per understood problem
class, not one per red test.

## UI test rules

- **Bounded loops only.** Never `for _ in 0..<n where !x.isHittable { swipe }`: `where`
  only skips the body, so the loop keeps taking accessibility snapshots for every
  remaining iteration. That alone pushed the review-queue and 1,000-entry import tests
  past their time allowance. Use `scroll(_:toReveal:)` / `reveal(_:in:)` from
  `Tests/UITests/UITestSupport.swift`, which stop at the first success.
- **Lazy lists.** `LazyVStack`/`List` rows aren't in the tree until scrolled to, and
  may drop out after scrolling past. Use `reveal`, which searches down and then up.
- **Scope queries.** Query by unique identifier within a known container
  (`header.staticTexts.matching(identifier:)`), not global labels like `"Cancel"` or
  `"Use This Video"` that several controls share. Give dialog buttons their own identifiers.
- **Wait for state.** After an action, use `waitUntil(element, predicate)` and don't
  assert immediately. No fixed sleeps.
- **Nested toggles.** A List-row Toggle reports the whole row as its frame (on iOS 26 the
  nested switch does too), so tapping its centre hits the label. Use `flipSwitch`, then
  check the model-visible effect (for example the "N selected" summary).
- **System UI.** The Files picker runs out of process and appears asynchronously. Wait
  for its dismiss control (Cancel/Close) explicitly.
- **Keep tests small.** One behaviour per test, each with its own isolated library
  (`MB_UI_TEST_ID` + `--reset-ui-library`). The default allowance is 60 s. Only tests that
  relaunch the app set `executionTimeAllowance = 120` (the workflow maximum), with a comment.
- **Accessibility structure is product surface.** Don't flatten or remove VoiceOver
  grouping to make a query work. Add a precise identifier instead.

## Fixture and async rules (unit tests)

- `LibraryFixture` deletes its database directory in `deinit`. Discarding it
  (`let (_, repo, id) = …`) or letting it go out of scope while repository work runs
  causes `vnode unlinked while in use` / `disk I/O error`. Call
  `retainUntilTeardown(fixture)`.
- Background work started with `Task { … }` must be registered with
  `cancelAndAwaitAtTeardown(task)`, *after* `retainUntilTeardown`, so a failing
  assertion can't leave it running against a deleted database.
- Never index (`array[3]`) after an assertion that might fail. Use bounds-checked
  helpers or `XCTUnwrap` so a failure reports instead of crashing the test process.
- Compare persisted identities against the exact source object you imported. Helper
  builders that generate UUIDs give different identities on each call.

## Keeping tests current after intended UX changes

When the product contract changes on purpose (new counter text, Add Songs on imported
playlists, `pending` instead of `needsReview` after cancellation, migration count):

1. Find every test that asserts the old behaviour, including the full-CI-only suites
   (`grep` the old string or identifier).
2. Update the assertion to the new contract and keep the guarantee it protected (for
   example "source order is preserved" stays when "no Add Songs" goes).
3. Add a test of the new behaviour itself, not only the absence of the old one.
