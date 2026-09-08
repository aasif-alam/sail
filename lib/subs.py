#!/usr/bin/env python3
"""Best-effort subtitle fetcher for sail, via the OpenSubtitles REST API v1.

Derives a search title (and season/episode, for TV releases) from a video
file's path, looks up the best-matching subtitle, downloads it, and writes
it to the given output path. Prints the output path on success; exits
non-zero with nothing on stdout otherwise, so the caller can treat a
missing subtitle as "none available" rather than an error.

Requires a free API key from https://www.opensubtitles.com/en/consumers,
passed via SAIL_OPENSUBTITLES_KEY. Uses only the Python standard library.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.opensubtitles.com/api/v1"
UA = "sail v1.2.0"

# quality/source/codec tags that mark where the release title ends
RELEASE_NOISE = re.compile(
    r"\b(2160p|1080p|720p|480p|hdr|bluray|blu-ray|webrip|web-dl|web|hdtv|"
    r"dvdrip|brrip|bdrip|x264|x265|hevc|avc|aac|ac3|dts|remux|proper|"
    r"repack|extended|unrated|limited|internal|multi|dubbed|subbed)\b",
    re.I,
)
EP_TAG = re.compile(r"[Ss](\d{1,2})[Ee](\d{1,3})")
YEAR = re.compile(r"\b(19|20)\d{2}\b")


def clean_query(path):
    """Best-effort (title, season, episode) from a release filename —
    same "good enough, fails soft" spirit as the title parsing already
    used for the episode-tag column in bin/sail's picker."""
    name = os.path.splitext(os.path.basename(path))[0]
    name = re.sub(r"[._]", " ", name)

    season = episode = None
    m = EP_TAG.search(name)
    if m:
        season, episode = int(m.group(1)), int(m.group(2))
        name = name[: m.start()]

    m = RELEASE_NOISE.search(name)
    if m:
        name = name[: m.start()]

    m = YEAR.search(name)
    if m:
        name = name[: m.start()]

    name = re.sub(r"\s+", " ", name).strip(" -")
    return name, season, episode


def api_request(path, api_key, data=None, timeout=8):
    url = f"{API_BASE}{path}"
    headers = {"Api-Key": api_key, "User-Agent": UA, "Content-Type": "application/json"}
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def find_file_id(title, season, episode, lang, api_key):
    params = {"query": title, "languages": lang}
    if season is not None:
        params["season_number"] = season
    if episode is not None:
        params["episode_number"] = episode
    results = api_request("/subtitles?" + urllib.parse.urlencode(params), api_key).get("data") or []
    if not results:
        return None
    best = max(results, key=lambda r: (r.get("attributes") or {}).get("download_count") or 0)
    files = (best.get("attributes") or {}).get("files") or []
    return files[0]["file_id"] if files else None


def download_link(file_id, api_key):
    data = api_request("/download", api_key, data={"file_id": file_id})
    return data.get("link")


def fetch(link, out_path, timeout=10):
    req = urllib.request.Request(link, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        content = r.read()
    with open(out_path, "wb") as f:
        f.write(content)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video_path", help="path (or filename) of the video to find subtitles for")
    ap.add_argument("out_path", help="where to save the downloaded subtitle")
    ap.add_argument("--lang", default="en")
    args = ap.parse_args()

    api_key = os.environ.get("SAIL_OPENSUBTITLES_KEY")
    if not api_key:
        print("SAIL_OPENSUBTITLES_KEY not set — skipping subtitles", file=sys.stderr)
        sys.exit(1)

    title, season, episode = clean_query(args.video_path)
    if not title:
        print(f"couldn't derive a search title from: {args.video_path}", file=sys.stderr)
        sys.exit(1)

    try:
        file_id = find_file_id(title, season, episode, args.lang, api_key)
        if not file_id:
            print(f"no subtitles found for {title!r} (lang={args.lang})", file=sys.stderr)
            sys.exit(1)
        link = download_link(file_id, api_key)
        if not link:
            print("no download link returned", file=sys.stderr)
            sys.exit(1)
        fetch(link, args.out_path)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        print(f"subtitle fetch failed: {e}", file=sys.stderr)
        sys.exit(1)

    print(args.out_path)


if __name__ == "__main__":
    main()
