# Local search and sorting

Your Library Search and the Library search field query real GRDB track rows by title,
artist and album (including optional album artist). Search uses canonical, case- and
diacritic-folded precomputed text, partial substring matching and bound SQL parameters.
Percent, underscore and backslash are escaped as literals. Empty/whitespace queries
return the collection; no results have a real empty state. Queries are capped at
500 characters. No request is made to a network service. YouTube mode remains a
clearly labelled future/mock surface, outside Phase 5.

Search waits 250 ms after input, runs away from the main actor, and discards cancelled
or outdated task results. A library revision also invalidates a search so metadata,
likes, deletion and import changes appear without relaunch. Queries use fixed enum
ORDER BY fragments, never user-supplied SQL. Indexes cover relationships, title, date
and duration; substring matching scans the prepared search text (not acoustic/FTS search).
This is appropriate for the intended hundreds/thousands of local tracks, not a claim
of indexed substring lookup at arbitrary scale.

Persistent library sorts:

- Name A-Z and Z-A (folded title).
- Artist A-Z using its stored normalized name, not UUID.
- Date Added newest and oldest.
- Numeric duration shortest and longest; unknown duration sorts last in both.

Stable track ID breaks ties. The selected mode is saved in settings.librarySort and
restored. Sorting changes browsing order, never saved custom playlist positions.
Playback captures the ordered visible selection at start, including search and liked
collections; later browsing changes do not rewrite the active playback snapshot.
