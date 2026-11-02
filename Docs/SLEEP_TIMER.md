# Sleep Timer

The timer supports 5, 10, 15, 30, 45, and 60 minute presets plus validated durations of at least one minute. It stores an absolute deadline, so foreground reconciliation remains correct after suspension. Cancel clears it; reset replaces the deadline. Expiration pauses the authoritative AVPlayer, preserves the current track and queue, and does not advance automatically.
