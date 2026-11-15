#!/usr/bin/env python3
"""Live smoke test of public Invidious search, mirroring the app's logic.

1. Loads HTTPS hosts from the official registry (api.invidious.io) plus the app's seed list.
2. Health-checks each host with the real search API (`/api/v1/search?q=music&type=video`).
3. Searches 20 representative songs on the fastest healthy host (0.5 s pacing, 8 s timeout).

Exit 0 when at least one song search completed, 2 when no public instance worked.
Never reports success it did not observe.
"""
import json, re, sys, time, urllib.error, urllib.parse, urllib.request

SEEDS = ["yt.chocolatemoo53.com", "inv.nadeko.net", "invidious.nerdvpn.de", "invidious.tiekoetter.com"]
REGISTRY = "https://api.invidious.io/instances.json?sort_by=type,users"
SONGS = [
    ("Daft Punk", "Get Lucky"), ("Adele", "Hello"), ("Queen", "Bohemian Rhapsody"), ("Dua Lipa", "Levitating"),
    ("The Weeknd", "Blinding Lights"), ("Ed Sheeran", "Shape of You"), ("Billie Eilish", "bad guy"),
    ("Coldplay", "Yellow"), ("Rihanna", "Umbrella"), ("Eminem", "Lose Yourself"), ("Shakira", "Hips Don't Lie"),
    ("Linkin Park", "Numb"), ("Taylor Swift", "Anti-Hero"), ("Bad Bunny", "Tití Me Preguntó"),
    ("Rammstein", "Du hast"), ("Stromae", "Alors on danse"), ("Dhurata Dora", "Zemër"), ("Era Istrefi", "Bonbon"),
    ("Nirvana", "Smells Like Teen Spirit"), ("Michael Jackson", "Billie Jean"),
]
ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
HOST = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
HEADERS = {"Accept": "application/json", "User-Agent": "MuzikBelesh-smoke-test/1.0"}

def get(url, timeout=8):
    start = time.monotonic()
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=timeout) as response:
        return json.loads(response.read(4_000_000)), time.monotonic() - start

def videos(payload):
    if not isinstance(payload, list):
        raise ValueError("not a JSON array")
    seen, out = set(), []
    for item in payload:
        if isinstance(item, dict) and item.get("type") == "video" and ID.match(str(item.get("videoId", ""))) and item.get("title"):
            if item["videoId"] not in seen:
                seen.add(item["videoId"]); out.append(item)
    return out

def search(host, query):
    q = urllib.parse.urlencode({"q": query, "type": "video"})
    payload, seconds = get(f"https://{host}/api/v1/search?{q}")
    return videos(payload), seconds

def main():
    hosts = list(SEEDS)
    try:
        rows, _ = get(REGISTRY, timeout=8)
        for name, info in rows:
            name = str(name).lower()
            if info.get("type") == "https" and info.get("api") is not False and HOST.match(name) and not re.match(r"^[0-9.]+$", name) and not name.endswith((".onion", ".i2p", ".ygg")) and name not in hosts:
                hosts.append(name)
        print(f"Registry: {len(hosts)} HTTPS host(s) to check")
    except Exception as error:
        print(f"Registry unavailable ({type(error).__name__}); using seed list")
    healthy = []
    for host in hosts[:12]:
        try:
            found, seconds = search(host, "music")
            if found:
                healthy.append((seconds, host)); print(f"HEALTHY {host}: {len(found)} videos in {seconds:.2f}s")
            else:
                print(f"UNHEALTHY {host}: search returned no videos")
        except urllib.error.HTTPError as error:
            print(f"UNAVAILABLE {host}: HTTP {error.code}")
        except Exception as error:
            print(f"UNAVAILABLE {host}: {type(error).__name__}")
        time.sleep(0.5)
    if not healthy:
        print("\nNo public Invidious instance answered the search API: live discovery NOT verified.")
        return 2
    host = min(healthy)[1]
    print(f"\nUsing {host}")
    completed = failures = covered = ids_total = 0
    latencies, errors = [], []
    for artist, title in SONGS:
        try:
            found, seconds = search(host, f"{artist} {title}")
            latencies.append(seconds); completed += 1; ids_total += len(found)
            words = {w for w in re.findall(r"\w+", title.lower()) if len(w) > 1}
            relevant = [v for v in found if words & set(re.findall(r"\w+", v["title"].lower()))]
            covered += bool(relevant)
            top = relevant[0] if relevant else None
            detail = f"{top['videoId']} '{top['title'][:50]}' {top.get('lengthSeconds')}s by {top.get('author')}" if top else "no relevant video"
            print(f"OK   {artist} - {title}: {len(found)} IDs, {seconds:.2f}s -> {detail}")
        except urllib.error.HTTPError as error:
            failures += 1; errors.append(f"{artist} - {title}: HTTP {error.code}")
        except Exception as error:
            failures += 1; errors.append(f"{artist} - {title}: {type(error).__name__}")
        time.sleep(0.5)
    for line in errors:
        print("FAIL " + line)
    total = sum(latencies)
    print(f"\nHealthy instances: {len(healthy)}/{min(len(hosts), 12)}")
    print(f"Requests completed: {completed}/{len(SONGS)}")
    print(f"Valid YouTube IDs returned: {ids_total}")
    print(f"Candidate coverage (relevant title): {covered}/{len(SONGS)} songs")
    print(f"Failures: {failures}")
    print(f"Latency: total {total:.2f}s, average {(total / completed if completed else 0):.2f}s")
    return 0 if completed else 2

if __name__ == "__main__":
    sys.exit(main())
