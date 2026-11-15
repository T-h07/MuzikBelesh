# Phase 10.4.8 — SearXNG discovery source

Discovery order per Spotify occurrence: local library → SearXNG (if enabled) → direct
YouTube (fallback, only when SearXNG returns no candidates or is unavailable) → manual link.
Each source has its own health state. A source in a verification/rate-limit cooldown is
skipped while another source can serve the song; the worker waits only when every source
is cooling down. SearXNG candidates are YouTube candidates for review only — never
downloaded or offline-ready. Each candidate records `Found by` (e.g. `searxng:bing videos`).

## Run a private instance (Windows + Docker Desktop)

```
cd Tools/searxng
set SEARXNG_SECRET=<long random string>
docker compose up -d
```

`settings.yml` enables only Bing/Google/Brave video engines and turns on JSON output
(`search.formats: [html, json]`). Without `json`, SearXNG returns HTTP 403 and the app
reports "SearXNG refused JSON output".

## Connect the iPhone

1. Find the PC's IPv4 address: `ipconfig` (e.g. `192.168.1.20`).
2. Allow inbound TCP 8080 in Windows Defender Firewall for private networks.
3. iPhone on the same Wi-Fi → Settings → Spotify Matching Sources:
   - Use SearXNG: on
   - Address: `http://192.168.1.20:8080`
   - Allow HTTP on local network (development): on (HTTP is accepted only for
     private LAN/localhost hosts; anything else must be HTTPS)
   - Save and Test Connection; allow the Local Network prompt.

The instance works only while the PC is on, Docker is running and both devices share
the network. When unreachable, matching falls back to direct YouTube (if enabled) and
unfinished songs stay retryable.

## Smoke test (20 songs)

```
python Scripts/searxng-smoke-test.py --base-url http://localhost:8080
```

Reports requests completed, valid YouTube IDs, candidate coverage, failures and
average/total latency. It makes no claim when no instance is reachable.
