# Phase 10.4.9 — Standalone iPhone discovery (public Invidious)

Default mode (**Automatic Discovery**) needs no PC, Docker, LAN or account:

1. Verified local audio
2. Public Invidious search — `GET https://{instance}/api/v1/search?q=…&type=video`
3. Optional self-hosted SearXNG (Settings → Advanced)
4. Direct YouTube search fallback
5. Manual YouTube link

A later source is called only when earlier ones found no candidates or are unavailable.

## Instance registry and health

- Seed hosts come from the official list (docs.invidious.io/instances); HTTPS domain hosts
  from `api.invidious.io/instances.json` are added once per launch (onion/i2p/ygg/IPs excluded).
- A host is "working" only after the real search API returned valid video results for a
  sample query — never because a home page loaded.
- Failover (once per query) only for connection/timeout/5xx/invalid responses.
- HTTP 429 is never evaded by switching hosts: the host cools down (10 min) and the
  Invidious source enters the matching service's provider cooldown; other sources continue.
- HTTP 401/403 ("Endpoint disabled", "credentials_required") marks the host unavailable for 1 h.
- When every host is down or cooling, Invidious reports `sourceUnavailable`; songs it could
  not search are deferred (retryable), never counted as searched.

Results are candidates only: no audio, track or download job is created. Instance-hosted
thumbnails are replaced by YouTube's CDN thumbnail for the same video ID.

Privacy: song titles and artist names are sent to the enabled third-party services.

## Live check (`python -X utf8 Scripts/invidious-smoke-test.py`), 2026-11-15

- Healthy instances: 1 of 6 checked (`yt.chocolatemoo53.com`); others: HTTP 403 "Endpoint
  disabled", HTTP 401 "credentials_required", HTTP 403, or unreachable.
- 20/20 searches completed, 400 valid IDs, 20/20 songs with a relevant title, 0 failures.
- Latency: average 3.99 s, total 79.8 s (health check alone 7.9 s).

Public availability is volunteer-run and changes; with one healthy instance there is no
redundancy. Re-run the script before device testing.
