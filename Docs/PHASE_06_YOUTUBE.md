# Phase 6 candidate: YouTube search and audio preparation

Status: implementation in progress; automated and physical acceptance are separate
gates. Phase 5 was merged by the developer in PR #6 at
`9ba81a7fe6d0cd6420958971ac2a89bfadb68264`. No Phase 7 media transfer is implemented.

## Dependency map and provider decision

`AppContainer` owns the search cache, metadata cache, local resolver, preferences,
artwork loader and download preparer. `SearchView` preserves the existing library
session and keyboard host; `YouTubeSearchResultsView` owns its observable search
state. Both search and Import Link open `VideoDetailView` with the same model.
The diagnostics probe delegates to the production resolver. Existing audio,
queue, history, timers, library schema and import/export services are unchanged.

`YouTubeSearchProvider`, `YouTubeMetadataProvider`, `YouTubeAudioResolver`,
`YouTubeTransport`, `YouTubeLibraryChecking`, and `YouTubeDownloadPreparing` are
injected boundaries. Network/JSON/extraction/image processing execute outside the
main actor. Observable state updates execute on the main actor.

Selected provider: anonymous YouTube web search, isolated in `YouTubeWebProvider`
and `YouTubeWebParser`. The initial HTTPS `/results` response supplies
`ytInitialData` and `ytcfg.INNERTUBE_CONTEXT`. Continuations POST to the same
YouTube `/youtubei/v1/search` endpoint using that response's client context.
No rotating client version, private credential, API key, cookies, third-party
instance or backend is embedded. No browser automation is used in the app.

This is **unofficial and not a stable public API**. Its tradeoff is direct no-key
operation at the cost of possible schema changes, consent blocks, bot challenges,
rate limits and region-specific failures. The parser recognizes a narrow set of
video renderers, ignores ads/other entity types, and reports unsupported layouts
as search unavailable rather than inventing results. Some Shorts-specific shelves
are omitted; regular video renderers carrying Shorts links are classified. The
provider interface allows replacement without changing UI or extraction.

Alternatives researched: the official [Data API search endpoint](https://developers.google.com/youtube/v3/docs/search/list)
requires API access credentials/quota; no shared key should ship in this app.
[b5i/YouTubeKit](https://github.com/b5i/YouTubeKit) is an independent unofficial
Swift search client but collides with the existing package/module name and adds
another substantial integration. Public proxy instances add a third-party service
and privacy/reliability dependency. No alternative gives a guaranteed stable,
official no-key search API. This provider makes that limitation explicit.

No additional licensed code was copied or runtime dependency added. Existing
[alexeichhorn/YouTubeKit](https://github.com/alexeichhorn/YouTubeKit/tree/0.4.10)
retains its upstream license. Search terms and the device's IP reach YouTube;
artwork requests reach allowlisted YouTube image hosts. Query, continuation and
image caches are memory-only. Nothing is sent to a developer-controlled service.

## Search, URLs, metadata and thumbnails

Queries trim/collapse whitespace and cap input at 500 characters. A 400 ms
cancellable debounce precedes the request. Generation checks reject late results
even from an uncooperative provider. A single visible Load More action prevents
duplicate page requests, deduplicates video IDs and detects repeated tokens.
No pages load automatically. Retry preserves existing rows on pagination failure.
The search service caches up to 20 query/page entries for 180 seconds with oldest
access eviction; `invalidate()` also prevents in-flight responses repopulating an
invalidated cache. A single screen task makes additional request coalescing
unnecessary. Metadata caches at most 20 entries for 30 seconds.

The expanded **existing** `YouTubeURLValidator` accepts an explicit 11-character
ASCII ID or HTTPS links with exact `youtube.com`, `www.youtube.com`,
`m.youtube.com`, or `youtu.be` hosts. Supported paths: `/watch?v=`, `/shorts/`,
`/embed/`, `/live/`, and the shortened single-ID path. Duplicate `v` parameters,
credentials, nonstandard ports, extra path segments, encoded separators, foreign
subdomains and non-HTTPS schemes are rejected with typed errors. Percent encoding
is decoded once. Unrelated query parameters cannot change identity. Share extension
compiles this same parser and preserves copy-link reception; automatic handoff is
still Phase 8.

The ordinary watch-page player JSON supplies author, channel ID, duration and
availability because YouTubeKit 0.4.10 publicly exposes only title, description
and thumbnail metadata. Nonempty extractor title/thumbnail override watch/search
values; absent values preserve prior metadata. The app never guesses missing
durations. Remote artwork is cancellable, downsampled off-main to 640 pixels and
cached for 180 seconds, at most 30 images. Images and redirects are restricted to
known YouTube thumbnail hosts; missing images use a neutral placeholder.

## Local extraction and stream selection

The inspected and exactly pinned package is **YouTubeKit 0.4.10**, revision
`89854c93207ad0d2b3d78d6f1aea24595ca66552`. The sole production construction uses
`YouTube(videoID: videoID, methods: extractionMethods)` where `extractionMethods`
is exactly `[.local]`; an integration assertion guards this. No remote fallback,
proxy, OAuth or cookie authentication is configured. The diagnostics adapter uses
the same resolver instance supplied by AppContainer.

The app checks the ordinary public watch response for `OK` and refuses login,
age/content verification, unavailable and unknown statuses before extraction.
It also rejects `youtube.ageRestricted` before requesting streams. No app code
attempts to solve challenges, log in, bypass regional restrictions or invoke an
age-gate workaround. Upstream local extraction itself uses multiple YouTube client
profiles; local does not imply a public/stable YouTube API.

One resolver serializes extraction across callers because the pinned package has
process-wide mutable JavaScript caches. Requests are cancellation-aware and use a
45-second cooperative deadline. Upstream operations must honor cancellation for
that deadline to finish; the UI cancels immediately and rejects stale completions.
App-owned network requests have 15-second request/25-second resource timeouts.
Failures map only to supported evidence; a generic rejection is not labeled a
region block without an explicit upstream region error.

Filter audio-only first, then require `isNativelyPlayable` and a known compatible
MP4/M4A codec combination (AAC/mp4a, AC-3 or E-AC-3). Prefer M4A/AAC before bitrate.
Within that group: Data Saver chooses the lowest known bitrate, Standard the
highest available bitrate at or below 128 kbps (otherwise the lowest), High the
highest. Unknown bitrate is used only if no known bitrate exists in the chosen
format group. Ties resolve by itag. No muxed/video-only selection, transcoding,
FFmpeg or lossless claims. All preferences can resolve to the same rate when that
is the only compatible option. `youtube.audioQuality` in UserDefaults persists
independently of SQLite and existing preferences.

The pinned version has **no `waitUntilAvailable()` API**. The replacement readiness
check performs HEAD only against HTTPS googlevideo hosts, refuses expired URLs,
checks a media content type, and waits two seconds between at most three checks
for 403/503 responses. A final 403 is reported as expired/rejected, not proof of a
specific restriction. No Range GET or media bytes are transferred. Other failures
are explicit; retries require user action. Signed URLs never appear in application
logs, view messages or persistent records. Descriptions redact them.

## Phase 7 handoff and data preservation

`YouTubeDownloadPreparing.prepare(video:quality:)` always asks the resolver for a
fresh stream and returns `PreparedYouTubeDownload`:

- stable `videoID`, normalized `metadata`, requested `quality`;
- selected format/codec/bitrate and enumerated audio options;
- short-lived URL, resolution timestamp and expiry when provided.

The request is deliberately not Codable. `VideoDetailsViewModel.preparedRequest`
is the documented in-memory handoff; the view shows preparation success and
explicitly says saving becomes available in Phase 7 and nothing was downloaded.
Leaving the screen or preparing again clears the request. Phase 7 must persist
only stable identity/quality and re-resolve immediately before starting transfer.
Even a successful HEAD is a momentary availability check, not a promise that a
later download will succeed.

`YouTubeLibraryLookup` reads `track_sources` by exact `sourceType = youtube` and
video ID, joins the actual stored track and checks local file availability. It
never matches titles, treats imported files without provenance as not downloaded,
and distinguishes missing files/storage errors. Existing schema already supports
this; **no migration or data reset is needed**. No Phase 6 service owns a player,
modifies queue/history/timer, imports files or inserts download jobs.

## Verification evidence and limits

Windows public-network checks on 2026-11-04: PSY search returned 19 video renderers;
continuation returned HTTP 200. Watch metadata returned `OK` for
`9bZkp7q19f0` (PSY), `HLYjoPv4QGY` (NEKO - N’FRONT), and `aqz-KE-bpKQ`
(Blender Foundation open-movie sample); `___________` returned `ERROR`. These
checks inspect public web responses, **not native YouTubeKit execution**.

Deterministic suites under `Tests/Unit/YouTube` cover strict URL handling, parser
fixtures/schema drift, dynamic continuation context, errors, debounce, stale
responses/cancellation, duplicate pagination, cache limits/expiry/invalidation,
metadata, compatible streams/quality fallback, bounded HEAD checks, redacted
handoff, persisted preferences, real SQLite provenance and playback/data invariants.
`YouTubeUITests` covers search/pagination/details/preparation/back, valid/invalid
paste input and local playback. Explicit DEBUG fixture injection requires both
`--ui-testing` and `--youtube-fixtures`, uses an isolated test library and preferences,
and is absent from Release. Production never substitutes fixtures on failure.

`YouTubeLiveTests` is skipped unless `MB_YOUTUBE_LIVE=1`. The CI dispatch option
`live_youtube` runs it separately with retained xcresult; failures measure external
compatibility and do not turn a deterministic failure green. The focused workflow
builds once, runs new tests plus the existing keyboard regression, and uploads
source-verified test products. Complete verification reuses those products and
packages one Release IPA only after required regressions pass. Native results,
exact source SHA, artifact and PR links are recorded in the delivery/PR evidence.

Physical acceptance is pending. See [the A–R checklist](PHASE_06_DEVICE_TESTING.md).
Media handling must respect content authorization and applicable platform restrictions.
