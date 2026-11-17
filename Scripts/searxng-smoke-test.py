#!/usr/bin/env python3
"""Smoke-test an explicitly configured SearXNG instance against 20 representative songs.

Usage: python Scripts/searxng-smoke-test.py --base-url http://localhost:8080 [--engines "bing videos,google videos,brave.videos"]
Exit code 0 when at least one request completed, 2 when the instance is unreachable/misconfigured.
"""
import argparse, json, re, sys, time, urllib.error, urllib.parse, urllib.request

SONGS = [
    ("Daft Punk", "Get Lucky"), ("Adele", "Hello"), ("Queen", "Bohemian Rhapsody"), ("Dua Lipa", "Levitating"),
    ("The Weeknd", "Blinding Lights"), ("Ed Sheeran", "Shape of You"), ("Billie Eilish", "bad guy"),
    ("Coldplay", "Yellow"), ("Rihanna", "Umbrella"), ("Eminem", "Lose Yourself"), ("Shakira", "Hips Don't Lie"),
    ("Linkin Park", "Numb"), ("Taylor Swift", "Anti-Hero"), ("Bad Bunny", "Tití Me Preguntó"),
    ("Rammstein", "Du hast"), ("Stromae", "Alors on danse"), ("Dhurata Dora", "Zemër"), ("Era Istrefi", "Bonbon"),
    ("Nirvana", "Smells Like Teen Spirit"), ("Michael Jackson", "Billie Jean"),
]
ID = re.compile(r"^[A-Za-z0-9_-]{11}$")

def video_id(url):
    """Mirror of SearXNGParser.videoID: individual HTTPS YouTube videos only."""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or parts.username or parts.password:
        return None
    if host == "youtu.be":
        candidate = parts.path.strip("/")
    elif host in ("youtube.com", "www.youtube.com", "m.youtube.com"):
        if parts.path == "/watch":
            values = urllib.parse.parse_qs(parts.query).get("v", [])
            candidate = values[0] if len(values) == 1 else ""
        else:
            segments = parts.path.split("/")
            candidate = segments[2] if len(segments) == 3 and segments[1] in ("shorts", "embed") else ""
    else:
        return None
    return candidate if ID.match(candidate or "") else None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--engines", default="bing videos,google videos,brave.videos")
    parser.add_argument("--timeout", type=float, default=8)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    completed = failures = covered = ids_total = 0
    latencies, errors = [], []
    for artist, title in SONGS:
        query = urllib.parse.urlencode({"q": f"{artist} {title}", "categories": "videos", "format": "json", "engines": args.engines})
        request = urllib.request.Request(f"{base}/search?{query}", headers={"Accept": "application/json"})
        start = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=args.timeout) as response:
                body = json.loads(response.read(4_000_000))
            latencies.append(time.monotonic() - start)
            completed += 1
            ids = {i for i in (video_id(r.get("url", "")) for r in body.get("results", [])) if i}
            ids_total += len(ids)
            covered += bool(ids)
            print(f"OK   {artist} - {title}: {len(ids)} YouTube video(s) in {latencies[-1]:.2f}s")
        except urllib.error.HTTPError as error:
            failures += 1
            errors.append(f"{artist} - {title}: HTTP {error.code}" + (" (JSON output disabled?)" if error.code == 403 else ""))
        except Exception as error:  # Unreachable host, timeout, malformed JSON.
            failures += 1
            errors.append(f"{artist} - {title}: {type(error).__name__}: {error}")
        time.sleep(0.3)  # Respectful pacing.
    for line in errors:
        print("FAIL " + line)
    total = sum(latencies)
    print(f"\nRequests completed: {completed}/{len(SONGS)}")
    print(f"Valid YouTube IDs returned: {ids_total}")
    print(f"Candidate coverage: {covered}/{len(SONGS)} songs")
    print(f"Failures: {failures}")
    print(f"Latency: total {total:.2f}s, average {(total / completed if completed else 0):.2f}s")
    if completed == 0:
        print("No usable SearXNG endpoint: integration NOT verified.")
        return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
