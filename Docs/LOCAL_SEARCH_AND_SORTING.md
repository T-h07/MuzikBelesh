# Local search and sorting

Search defaults to Your Library. It and the persistent Library search field share
one universal result model: songs by title/artist/album/album artist, album groups
by title/album artist, performer artists by name, and playlists by name/description.
Every entity comes from the observed GRDB snapshot. Songs play and collection
results open their stable-ID details; mock music is never returned as local data.
YouTube remains a clearly marked future/mock surface, outside Phase 5.

All shows nonempty Songs, Albums, Artists and Playlists sections with counts. A
specific category restricts the same matches; Liked Songs also applies the persisted
liked-ID set. The field is available in every Library category, and switching filters
keeps the query. A genuine empty match displays an empty state; initial search shows
progress rather than falsely claiming the collection is empty.

Matching normalizes whitespace, canonical Unicode, case and diacritics, then caps
the query at 500 characters. Percent, underscore and backslash are literal characters.
Empty/whitespace queries return the collection. Universal matching filters immutable
persisted snapshots on a detached task, not the UI thread. Query changes debounce
250 ms; library revisions refresh matches for imports, edits, playlist CRUD and likes.
A request generation and cancellation check prevent older responses from replacing
newer results. This is an in-memory substring scan appropriate for local collections,
not indexed full-text or acoustic search. The existing bound-SQL track search remains
available to the playlist song picker; neither path interpolates query text as SQL.

The root owns native search focus for both fields. Search/Return and the accessible
keyboard Done control dismiss it. Scrolling results dismisses immediately. Query
clearing, tab changes, navigation, result playback, sheets and backgrounding release
focus. The root sizes the native tab controller to the available keyboard-safe region,
keeping the real tab bar reachable above the keyboard. The mini-player and Sleep Timer
continue to use safe-area insets above that bar. Keyboard,
tab and player accessibility are verified in UI tests and require physical retesting.

Persistent library sorts:

- Name A-Z and Z-A (folded title).
- Artist A-Z using its stored normalized name, not UUID.
- Date Added newest and oldest.
- Numeric duration shortest and longest; unknown duration sorts last in both.

Stable track ID breaks ties. The selected mode is saved in settings.librarySort and
restored. Sorting changes browsing order, never saved custom playlist positions.
Playback captures the ordered visible selection at start, including search and liked
collections; later browsing changes do not rewrite the active playback snapshot.
