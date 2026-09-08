#!/usr/bin/env python3
"""Torrent search backend for sail.

Queries multiple public sources in parallel and prints results as TSV:
    id<TAB>seeders<TAB>size<TAB>source<TAB>title<TAB>age<TAB>magnet

If a row's magnet is "FETCH:<url>", the caller must fetch the torrent
detail page to extract the magnet (used for scraped sources like 1337x).
Uses only the Python standard library.
"""

import concurrent.futures
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36")

# Public trackers appended to every magnet link (per BEP-0012 / WebTorrent)
TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.tracker.cl:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "wss://tracker.openwebtorrent.com",
    "wss://tracker.webtorrent.dev",
    "wss://tracker.btorrent.xyz",
    "wss://tracker.files.fm:7073/announce",
]

MIRRORS_1337X = ["1337x.to", "1337x.st", "x1337x.se", "1377x.to"]


def http_get(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def http_json(url, timeout=6):
    return json.loads(http_get(url, timeout))


def first_success(fns):
    """Run zero-arg callables in parallel; return the first one that both
    succeeds and returns a truthy result. Used for sources that mirror the
    same search across multiple hosts — trying hosts one at a time means a
    single dead host multiplies the wait by its own timeout; racing them
    bounds the whole thing to about one timeout, no matter how many hosts."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(fns)) as ex:
        futs = [ex.submit(fn) for fn in fns]
        for fut in concurrent.futures.as_completed(futs):
            try:
                result = fut.result()
            except Exception:
                continue
            if result:
                return result
    return []


def human_size(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def ago(epoch):
    """Relative age like '3mo ago' from a unix timestamp."""
    try:
        d = time.time() - int(epoch)
    except (TypeError, ValueError):
        return "?"
    if d < 0:
        return "?"
    for unit, secs in (("y", 31536000), ("mo", 2592000),
                       ("d", 86400), ("h", 3600), ("m", 60)):
        if d >= secs:
            return f"{int(d // secs)}{unit} ago"
    return "just now"


def magnet_from_hash(info_hash, name):
    tr = "&".join("tr=" + urllib.parse.quote(t) for t in TRACKERS)
    return (f"magnet:?xt=urn:btih:{info_hash}"
            f"&dn={urllib.parse.quote(name)}&{tr}")


# ---------------------------------------------------------------- sources

def search_apibay(query):
    """The Pirate Bay unofficial JSON API."""
    data = http_json("https://apibay.org/q.php?q=" + urllib.parse.quote(query))
    out = []
    for t in data:
        if not isinstance(t, dict) or t.get("id") in ("0", None):
            continue
        if int(t.get("seeders", 0) or 0) <= 0:
            continue
        out.append({
            "title": html.unescape(t["name"]),
            "seeders": int(t.get("seeders", 0) or 0),
            "size": human_size(t.get("size", 0)),
            "source": "tpb",
            "age": ago(t.get("added")),
            "magnet": magnet_from_hash(t["info_hash"], t["name"]),
        })
    return out


def search_yts(query):
    """YTS.mx — movies, high-quality releases."""
    data = http_json("https://yts.mx/api/v2/list_movies.json?limit=20&queryterm="
                     + urllib.parse.quote(query))
    out = []
    for m in (data.get("data") or {}).get("movies") or []:
        for t in m.get("torrents") or []:
            out.append({
                "title": f"{m['title']} ({m['year']}) "
                         f"{t['quality']} {t['type']}",
                "seeders": int(t.get("seeds", 0) or 0),
                "size": t.get("size", "?"),
                "source": "yts",
                "age": "?",
                "magnet": magnet_from_hash(t["hash"], m["title_long"]),
            })
    return out


def search_eztv(query):
    """EZTV — TV episodes."""
    data = http_json("https://eztvx.to/api/get-torrents?limit=100"
                     "&search=" + urllib.parse.quote(query))
    out = []
    for t in data.get("torrents") or []:
        magnet = t.get("magnet_url") or ""
        if not magnet:
            continue
        out.append({
            "title": html.unescape(t.get("title", "?")),
            "seeders": int(t.get("seeds", 0) or 0),
            "size": human_size(t.get("size_bytes", 0)),
            "source": "eztv",
            "age": ago(t.get("date_based")),
            "magnet": magnet,
        })
    return out


def search_1337x(query):
    """Scrape 1337x via whichever mirror responds first."""
    def try_host(host):
        page = http_get(f"https://{host}/search/{urllib.parse.quote(query)}/1/")
        results = []
        # search page rows: capture link + name from the results table
        for m in re.finditer(
                r'href="/torrent/(\d+)/([^"/]+)/"[^>]*>([^<]+)</a>', page):
            _id, slug, name = m.groups()
            results.append({
                "title": html.unescape(name.strip()),
                "seeders": 0,
                "size": "?",
                "source": "1337x",
                "age": "?",
                "magnet": f"FETCH:https://{host}/torrent/{_id}/{slug}/",
            })
        return results
    return first_success([lambda h=host: try_host(h) for host in MIRRORS_1337X])


SOURCES = {
    "tpb": search_apibay,
    "yts": search_yts,
    "eztv": search_eztv,
    "1337x": search_1337x,
}


# ------------------------------------------------------- additional sources

def search_solidtorrents(query):
    """Solid Torrents — JSON API, general purpose."""
    data = http_json("https://api.solidtorrents.to/v1/search?sort=seeders&q="
                     + urllib.parse.quote(query))
    out = []
    for t in (data.get("results") or []):
        if not t.get("magnet") and not t.get("info_hash_v1"):
            continue
        magnet = t.get("magnet") or magnet_from_hash(t["info_hash_v1"], t["title"])
        out.append({
            "title": t.get("title", "?"),
            "seeders": int(t.get("seeders", 0) or 0),
            "size": t.get("size", "?"),
            "source": "solid",
            "age": ago(t.get("updatedAt")),
            "magnet": magnet,
        })
    return out


def search_nyaa(query):
    """Nyaa — anime and Asian media. Scraped from the search table."""
    page = http_get("https://nyaa.si/?q=" + urllib.parse.quote(query)
                    + "&sort=seeders&order=desc")
    out = []
    for row in re.findall(r'<tr class="(?:default|success|danger)">(.*?)</tr>',
                          page, re.S):
        t = re.search(r'<a href="/view/\d+"[^>]*title="([^"]+)"', row)
        if not t:
            continue
        m = re.search(r'href="(magnet:\?[^"]+)"', row)
        sz = re.search(r'<td class="text-center">([\d.]+ [KMGTP]iB)</td>', row)
        ts = re.search(r'data-timestamp="(\d+)"', row)
        seeds = re.findall(r'<td class="text-center">(\d+)</td>', row)
        mh = re.search(r'btih:([0-9A-Fa-f]{40})', row)
        if m:
            magnet = html.unescape(m.group(1))
        elif mh:
            magnet = magnet_from_hash(mh.group(1), t.group(1))
        else:
            continue
        out.append({
            "title": html.unescape(t.group(1)),
            "seeders": int(seeds[0]) if seeds else 0,
            "size": sz.group(1).replace("iB", "B") if sz else "?",
            "source": "nyaa",
            "age": ago(ts.group(1)) if ts else "?",
            "magnet": magnet,
        })
    return out


def search_torlock(query):
    """Torlock — general purpose, scraped."""
    page = http_get("https://torlock.com/search/"
                    + urllib.parse.quote(query) + "/1/")
    out = []
    for m in re.finditer(
            r'href="/torrent/(\d+)/([^"]+)\.html"[^>]*>([^<]+)</a>'
            r'.*?<td[^>]*>([\d.]+ [KMG]B)</td>'
            r'.*?<td[^>]*>(\d+)</td>', page, re.S):
        _id, _slug, name, size, seed = m.groups()
        out.append({
            "title": html.unescape(name.strip()),
            "seeders": int(seed),
            "size": size,
            "source": "torlock",
            "age": "?",
            "magnet": f"FETCH:https://torlock.com/torrent/{_id}/{_slug}.html",
        })
    return out


def search_torrentgalaxy(query):
    """TorrentGalaxy — general purpose, scraped."""
    page = http_get("https://torrentgalaxy.to/torrents.php?search="
                    + urllib.parse.quote(query) + "&sort=seeders&order=desc")
    out = []
    for m in re.finditer(
            r'href="/torrent/(\d+)/([^"]+)"[^>]*title="([^"]+)"(.+?)</tr>',
            page, re.S):
        _id, _slug, name, rest = m.groups()
        seed = re.search(
            r'pen montbold text-success[^>]*>\s*<b[^>]*>([\d,]+)', rest)
        size = re.search(r'pen montbold[^>]*>\s*<b[^>]*>([\d.]+ [KMG]B)', rest)
        out.append({
            "title": html.unescape(name.strip()),
            "seeders": int((seed.group(1) if seed else "0").replace(",", "")),
            "size": size.group(1) if size else "?",
            "source": "tgx",
            "age": "?",
            "magnet": f"FETCH:https://torrentgalaxy.to/torrent/{_id}/{_slug}",
        })
    return out


def search_limetorrents(query):
    """LimeTorrents — general purpose, scraped, whichever mirror responds first."""
    def try_host(host):
        page = http_get(f"https://{host}/search/"
                        + urllib.parse.quote(query) + "/1/")
        out = []
        for m in re.finditer(
                r'href="/torrent/(\d+)/([^"]+)"[^>]*title="([^"]+)"'
                r'.*?<td[^>]*>([\d.]+ [KMGTP]B)</td>\s*<td[^>]*>(\d+)',
                page, re.S):
            _id, _slug, name, size, seed = m.groups()
            out.append({
                "title": html.unescape(name.strip()),
                "seeders": int(seed),
                "size": size,
                "source": "lime",
                "age": "?",
                "magnet": f"FETCH:https://{host}/torrent/{_id}/{_slug}",
            })
        return out
    return first_success([lambda h=host: try_host(h)
                          for host in ("limetorrents.lol", "limetorrents.pro")])


def search_knaben(query):
    """Knaben — aggregator with its own index, scraped table with magnets."""
    page = http_get("https://knaben.org/search/"
                    + urllib.parse.quote(query) + "/0/1/seeders?unsafe=true")
    out = []
    for h, body in re.findall(
            r'<tr class="text-nowrap[^"]*" data-id="([0-9a-fA-F]{40})"(.*?)</tr>',
            page, re.S):
        t = re.search(r'<a title="([^"]+)" href="(magnet:\?[^"]+)"', body)
        if not t:
            continue
        tds = re.findall(r'<td[^>]*>(.*?)</td>', body, re.S)
        cell = lambda k: re.sub(r"<[^>]+>", " ", tds[k]).strip() if len(tds) > k else "?"
        out.append({
            "title": html.unescape(t.group(1)),
            "seeders": int(cell(4) or 0),
            "size": cell(2),
            "source": "knaben",
            "age": ago(time.mktime(time.strptime(cell(3), "%Y-%m-%d"))
                       if re.match(r"\d{4}-\d{2}-\d{2}$", cell(3)) else None),
            "magnet": html.unescape(t.group(2)),
        })
    return out


def search_torrentscsv(query):
    """Torrents-CSV — open-source DHT-crawled index, clean JSON API."""
    data = http_json("https://torrents-csv.com/service/search?q="
                     + urllib.parse.quote(query))
    out = []
    for t in data.get("torrents") or []:
        out.append({
            "title": t.get("name", "?"),
            "seeders": int(t.get("seeders", 0) or 0),
            "size": human_size(t.get("size_bytes", 0)),
            "source": "tcsv",
            "age": ago(t.get("created_unix")),
            "magnet": magnet_from_hash(t["infohash"], t.get("name", "")),
        })
    return out


def search_torrentquest(query):
    """TorrentQuest — aggregator, scraped. Rows carry magnet + stats inline."""
    page = http_get("https://torrentquest.com/i/" + urllib.parse.quote(query)
                    + "/", timeout=8)
    out = []
    for row in re.split(r"<tr", page):
        m = re.search(r'href="(magnet:\?xt=urn:btih:[^"]+)"', row)
        t = re.search(r'href="/file/\d+/[^"]*"[^>]*title="([^"]+)"', row)
        if not (m and t):
            continue
        sz = re.search(r"<td>([\d.]+ ?[KMGTP]B)</td>", row)
        seed = re.search(r'<td class="s">(\d+)</td>', row)
        age = re.search(r"<td>(\d+ [a-z]+(?: [a-z]+)?|\d+[hdmy])</td>", row)
        out.append({
            "title": html.unescape(t.group(1)),
            "seeders": int(seed.group(1)) if seed else 0,
            "size": sz.group(1) if sz else "?",
            "source": "tq",
            "age": age.group(1) if age else "?",
            "magnet": html.unescape(m.group(1)),
        })
    return out


def search_extratorrent(query):
    """ExtraTorrent clone (extratorrent.st) — scraped, magnets inline."""
    page = http_get("https://extratorrent.st/search/?search="
                    + urllib.parse.quote(query), timeout=8)
    out = []
    for row in re.split(r"<tr", page):
        if "btih:" not in row:
            continue
        m = re.search(r'href="(magnet:\?xt=urn:btih:[^"]+)"', row)
        t = re.search(r'href="/torrent/\d+/[^"]+"[^>]*title="view ([^"]+) torrent"',
                      row)
        if not (m and t):
            continue
        sz = re.search(r"<td>([\d.]+ [KMGTP]B)</td>", row)
        seed = re.search(r'<td class="sn">(\d+)</td>', row)
        age = re.search(r"<td>(\d+[hdmyw]|\d+ days|\d+ months|\d+ years)</td>", row)
        out.append({
            "title": html.unescape(t.group(1)),
            "seeders": int(seed.group(1)) if seed else 0,
            "size": sz.group(1) if sz else "?",
            "source": "et",
            "age": age.group(1) if age else "?",
            "magnet": html.unescape(m.group(1)),
        })
    return out


ALL_SOURCES = dict(SOURCES)
ALL_SOURCES.update({
    "knaben": search_knaben,
    "tcsv": search_torrentscsv,
    "tq": search_torrentquest,
    "et": search_extratorrent,
    "solid": search_solidtorrents,
    "nyaa": search_nyaa,
    "torlock": search_torlock,
    "tgx": search_torrentgalaxy,
    "lime": search_limetorrents,
})

SOURCE_INFO = {
    "tpb":    "The Pirate Bay (general)",
    "yts":    "YTS (movies)",
    "eztv":   "EZTV (TV episodes)",
    "knaben": "Knaben (aggregator, well seeded)",
    "tcsv":   "Torrents-CSV (DHT crawled, open data)",
    "tq":     "TorrentQuest (aggregator)",
    "et":     "ExtraTorrent (movies / general)",
    "solid":  "Solid Torrents (general)",
    "nyaa":   "Nyaa (anime / asian media)",
    "1337x":  "1337x (general)",
    "torlock": "Torlock (general, verified)",
    "tgx":    "TorrentGalaxy (general)",
    "lime":   "LimeTorrents (general)",
}

DEFAULT_ENABLED = ["tpb", "yts", "eztv", "knaben", "tcsv", "solid"]


def config_path():
    return os.path.expanduser(
        os.environ.get("SAIL_SOURCES", "~/.config/sail/sources.conf"))


def load_enabled():
    """Enabled source names, from the config file (all if it doesn't exist)."""
    path = config_path()
    if not os.path.exists(path):
        return list(DEFAULT_ENABLED)
    enabled = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line in ALL_SOURCES:
            enabled.append(line)
    return enabled or list(DEFAULT_ENABLED)


def magnet_from_detail(url):
    """Fetch a scraped detail page and pull out its magnet link."""
    page = http_get(url, timeout=8)
    m = re.search(r'href="(magnet:\?xt=urn:btih:[^"]+)"', page)
    if not m:
        raise RuntimeError(f"no magnet found at {url}")
    return html.unescape(m.group(1))


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--list-sources":
        for name in ALL_SOURCES:
            print(f"{name}\t{SOURCE_INFO[name]}")
        return
    if argv and argv[0].startswith("--sources="):
        enabled = [s for s in argv[0].split("=", 1)[1].split(",")
                   if s in ALL_SOURCES]
        argv = argv[1:]
    else:
        enabled = load_enabled()
    if not argv or not " ".join(argv).strip():
        print("usage: search.py [--sources=a,b,c] <query>", file=sys.stderr)
        sys.exit(1)
    query = " ".join(argv).strip()

    results = []
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=9) as ex:
        futs = {ex.submit(ALL_SOURCES[name], query): name
                for name in enabled}
        for fut in concurrent.futures.as_completed(futs):
            try:
                results.extend(fut.result())
            except Exception as e:
                errors.append(f"{futs[fut]}: {e}")

    # relevance filter: every significant query word must appear in the
    # title. Some sources (e.g. EZTV) ignore the search param and return
    # everything; without this the list fills with unrelated torrents.
    tokens = [t for t in re.split(r"\W+", query.lower()) if len(t) > 2]
    if tokens:
        results = [r for r in results if all(
            t in r["title"].lower() for t in tokens)]

    # de-dup by title, keep best-seeded
    seen = {}
    for r in results:
        key = r["title"].lower()
        if key not in seen or r["seeders"] > seen[key]["seeders"]:
            seen[key] = r
    results = sorted(seen.values(), key=lambda r: -r["seeders"])

    for i, r in enumerate(results):
        print("\t".join([
            str(i), str(r["seeders"]), r["size"], r["source"],
            r["title"].replace("\t", " "), r.get("age", "?"), r["magnet"],
        ]))

    if not results:
        for e in errors:
            print(f"  [source error] {e}", file=sys.stderr)
        print("No results found.", file=sys.stderr)


if __name__ == "__main__":
    main()
