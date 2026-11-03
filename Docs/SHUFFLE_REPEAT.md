# Shuffle and Repeat

Shuffle creates a persisted, repeat-free cycle from the active available library context. The stored order and position make the cycle restorable; explicit duplicate queue occurrences remain deliberate duplicates.

Repeat cycles `Off → All → One`. Off stops when the context ends, All starts the context again (with a new shuffle cycle when enabled), and One repeats the current track on natural completion. Manual Previous and Next remain navigation commands.

Current policy: explicit queue entries take precedence; after Previous, Next follows
recorded forward history. Otherwise Repeat One replays the current track for Next
and completion. Shuffle checks use the remaining cycle rather than indexed position;
a single-track Repeat All cycle replays that track. Unchanged context refresh preserves
the cursor; library removal reconciles consumed/remaining segments independently.
