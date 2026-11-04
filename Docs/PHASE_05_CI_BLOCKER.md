# Bounded verification after run 41825532405

Source investigated: `2269a4f62d07f00d2e9b81e0ca102c5a697f0921`.
The downloaded KeyboardResults.xcresult SQLite record reports one failure:
`Test exceeded execution time allowance of 2 minutes`, duration 120 seconds.
There is no recorded failed control/focus assertion in that case.

The last completed XCTest activity was `Tap "Clear search" Button` (2.7 seconds).
Before that, tab switching and dragging results completed, and their keyboard-absent
predicates succeeded. The log was checking keyboard absence again when the budget
expired. The screenshot shows Search, Done, player, timer and tabs correctly placed.
The exported spindump says `No samples`; it does not establish a blocked app thread.
The evidence identifies a progressing automation workflow killed by its budget,
rather than demonstrating the reported keyboard softlock.

One targeted correction makes DEBUG UI-test WAVs 180 seconds instead of two seconds.
The old clips advanced through playback/history while XCTest took snapshots. Removing
that unrelated endpoint churn is the hypothesis tested by the single focused attempt.
All control/focus assertions and the original 120-second cap are retained. Short
endpoint fixtures in unit/integration tests are unchanged. The timeout-increase
commit from the interrupted command is reverted.

Old artifacts contain xcresult/attachments, not reusable compiled products. The
focused attempt must build this changed DEBUG fixture once. It retains those products
with their source SHA; the one allowed final attempt reuses them without rebuilding
the simulator application, runs every mandatory test, then packages the device IPA
only if all checks pass. No further attempt is authorized if either attempt fails.
