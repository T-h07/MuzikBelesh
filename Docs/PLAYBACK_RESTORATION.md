# Playback Restoration

The persisted snapshot contains the selected track, millisecond position, explicit queue, context IDs, shuffle order/position, repeat mode, and sleep-timer deadline. Cold launch restores the AVPlayer item paused. Unavailable tracks are removed from the queue and a missing current track is reported without corrupting the database.
