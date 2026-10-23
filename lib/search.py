#!/usr/bin/env python3
"""Torrent search backend for sail.

Queries multiple public sources in parallel and prints results as TSV:
    id<TAB>seeders<TAB>size<TAB>source<TAB>title<TAB>age<TAB>magnet

Other modes, all used by bin/sail:
    --list-sources   name<TAB>description<TAB>enabled-by-default
    --enabled        one enabled source name per line (the config file,
                     or the defaults when it is missing)
    --json           print a JSON array instead of TSV (for `sail --json`)

If a row's magnet is "FETCH:<url>", the caller must fetch the torrent
detail page to extract the magnet (used for scraped sources like 1337x).
Uses only the Python standard library.
"""

import html
import hashlib
import json
import os
import queue
import re
import sys
import threading
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


def http_get(url, timeout=4):
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
    bounds the whole thing to about one timeout, no matter how many hosts.

    Plain daemon threads, not ThreadPoolExecutor: a pool's worker threads
    are joined at interpreter exit even after shutdown(wait=False), so
    returning early here wouldn't stop a slow, still-running mirror from
    holding up the whole search.py process afterwards — daemon threads
    are simply dropped when the process exits."""
    q = queue.Queue()

    def run(fn):
        try:
            q.put(fn())
        except Exception:
            q.put(None)

    for fn in fns:
        threading.Thread(target=run, args=(fn,), daemon=True).start()

    for _ in fns:
        try:
            result = q.get(timeout=10)
        except queue.Empty:
            break
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


def _int(value, default=0):
    """int() that tolerates commas, whitespace, and scraped junk."""
    try:
        return int(str(value).replace(",", "").strip())
    except (TypeError, ValueError):
        return default


def _clean_title(value):
    """Single-line title: unescape entities and collapse all whitespace."""
    text = html.unescape(str(value if value is not None else "?"))
    text = re.sub(r"\s+", " ", text).strip()
    return text or "?"


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
        if _int(t.get("seeders")) <= 0:
            continue
        title = _clean_title(t.get("name"))
        out.append({
            "title": title,
            "seeders": _int(t.get("seeders")),
            "size": human_size(_int(t.get("size"))),
            "source": "tpb",
            "age": ago(t.get("added")),
            "magnet": magnet_from_hash(t["info_hash"], title),
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
                "title": _clean_title(
                    f"{m['title']} ({m['year']}) {t['quality']} {t['type']}"),
                "seeders": _int(t.get("seeds")),
                "size": t.get("size", "?"),
                "source": "yts",
                # YTS publishes upload times per movie and per torrent;
                # either is better than the blank column this used to show
                "age": ago(t.get("date_uploaded_unix")
                           or m.get("date_uploaded_unix")),
                "magnet": magnet_from_hash(
                    t["hash"], _clean_title(m.get("title_long") or m["title"])),
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
            "title": _clean_title(t.get("title", "?")),
            "seeders": _int(t.get("seeds")),
            "size": human_size(t.get("size_bytes", 0)),
            "source": "eztv",
            # the API field is date_released_unix; date_based was never
            # present and silently made every EZTV row "?"
            "age": ago(t.get("date_released_unix") or t.get("date_based")),
            "magnet": magnet,
        })
    return out


def search_1337x(query):
    """Scrape 1337x via whichever mirror responds first."""
    def try_host(host):
        page = http_get(f"https://{host}/search/{urllib.parse.quote(query)}/1/")
        results = []
        # one <tr> per result; the name cell also holds an icon-only anchor
        # with the same href, so keep looking until an anchor has text
        for row in re.split(r"<tr\b", page):
            name = ""
            for m in re.finditer(
                    r'href="/torrent/(\d+)/([^"/]+)/"[^>]*>(.*?)</a>',
                    row, re.S):
                text = re.sub(r"<[^>]+>", "", m.group(3)).strip()
                if text:
                    _id, slug, name = m.group(1), m.group(2), text
                    break
            if not name:
                continue
            seed = re.search(
                r'class="[^"]*coll-2[^"]*"[^>]*>\s*([\d,]+)', row)
            size = re.search(
                r'class="[^"]*coll-4[^"]*"[^>]*>\s*([\d.]+\s*[KMGTP]?B)',
                row)
            results.append({
                "title": _clean_title(name),
                "seeders": _int(seed.group(1)) if seed else 0,
                "size": re.sub(r"\s+", "", size.group(1)) if size else "?",
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
            "title": _clean_title(t.get("title", "?")),
            "seeders": _int(t.get("seeders")),
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
        # the seeders cell carries the success color class, so a bare
        # class="text-center" match (the size/downloads cells) never found it
        seeds = re.search(
            r'<td class="[^"]*text-success[^"]*"[^>]*>\s*([\d,]+)', row)
        mh = re.search(r'btih:([0-9A-Fa-f]{40})', row)
        if m:
            magnet = html.unescape(m.group(1))
        elif mh:
            magnet = magnet_from_hash(mh.group(1), t.group(1))
        else:
            continue
        out.append({
            "title": _clean_title(t.group(1)),
            "seeders": _int(seeds.group(1)) if seeds else 0,
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
            "title": _clean_title(name),
            "seeders": _int(seed),
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
            "title": _clean_title(name),
            "seeders": _int(seed.group(1)) if seed else 0,
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
                "title": _clean_title(name),
                "seeders": _int(seed),
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

        def cell(k, tds=tds):
            return (re.sub(r"<[^>]+>", " ", tds[k]).strip()
                    if len(tds) > k else "?")

        out.append({
            "title": _clean_title(t.group(1)),
            "seeders": _int(cell(4)),
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
        title = _clean_title(t.get("name"))
        out.append({
            "title": title,
            "seeders": _int(t.get("seeders")),
            "size": human_size(_int(t.get("size_bytes"))),
            "source": "tcsv",
            "age": ago(t.get("created_unix")),
            "magnet": magnet_from_hash(t["infohash"], title),
        })
    return out


def search_torrentquest(query):
    """TorrentQuest — aggregator, scraped. Rows carry magnet + stats inline."""
    page = http_get("https://torrentquest.com/i/" + urllib.parse.quote(query)
                    + "/", timeout=5)
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
            "title": _clean_title(t.group(1)),
            "seeders": _int(seed.group(1)) if seed else 0,
            "size": sz.group(1) if sz else "?",
            "source": "tq",
            "age": age.group(1) if age else "?",
            "magnet": html.unescape(m.group(1)),
        })
    return out


def search_extratorrent(query):
    """ExtraTorrent clone (extratorrent.st) — scraped, magnets inline."""
    page = http_get("https://extratorrent.st/search/?search="
                    + urllib.parse.quote(query), timeout=5)
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
            "title": _clean_title(t.group(1)),
            "seeders": _int(seed.group(1)) if seed else 0,
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


def read_config():
    """(enabled, unknown) source names from the config file.

    A missing file means DEFAULT_ENABLED. An existing file is authoritative
    even when it is empty: that means search no sources (the UI writes an
    empty file when the user saves with everything toggled off). Unknown
    names are returned separately so callers can point out a typo instead
    of silently searching fewer sources."""
    path = config_path()
    if not os.path.exists(path):
        return list(DEFAULT_ENABLED), []
    enabled, unknown, seen = [], [], set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in ALL_SOURCES:
                if line not in seen:
                    seen.add(line)
                    enabled.append(line)
            elif line not in unknown:
                unknown.append(line)
    return enabled, unknown


def load_enabled():
    """Enabled source names, exactly as the config file lists them."""
    return read_config()[0]


def magnet_from_detail(url):
    """Fetch a scraped detail page and pull out its magnet link."""
    page = http_get(url, timeout=5)
    m = re.search(r'href="(magnet:\?xt=urn:btih:[^"]+)"', page)
    if not m:
        raise RuntimeError(f"no magnet found at {url}")
    return html.unescape(m.group(1))


def filter_relevant(results, query):
    """Drop rows missing a significant query word.

    Some sources (e.g. EZTV) ignore the search param and return everything;
    without this the list fills with unrelated torrents."""
    tokens = [t for t in re.split(r"\W+", query.lower()) if len(t) > 2]
    if not tokens:
        return results
    return [r for r in results if all(
        t in r["title"].lower() for t in tokens)]


def dedupe_sorted(results):
    """One row per title, keeping the best-seeded copy, seeds first."""
    seen = {}
    for r in results:
        key = r["title"].lower()
        if key not in seen or r["seeders"] > seen[key]["seeders"]:
            seen[key] = r
    return sorted(seen.values(), key=lambda r: -r["seeders"])


def search_timeout():
    """Overall wall-clock budget (seconds) the whole search phase may spend.

    SAIL_SEARCH_TIMEOUT overrides it; a bogus value falls back to the
    default, and it never goes below one second so a typo'd env var can't
    turn into "0 s budget" and drop every source instantly."""
    try:
        budget = float(os.environ.get("SAIL_SEARCH_TIMEOUT", "6"))
    except ValueError:
        budget = 6.0
    return max(1.0, budget)


# --------------------------------------------------------------- cache

CACHE_TTL = 300.0  # seconds one (source, query) answer stays fresh


def cache_dir():
    """Where per-source answers are cached; created on demand.

    SAIL_CACHE_DIR overrides it (tests use that for hermeticity); normally
    it lives under the XDG cache dir, falling back to ~/.cache."""
    base = os.environ.get("SAIL_CACHE_DIR")
    if not base:
        base = os.path.join(
            os.environ.get("XDG_CACHE_HOME")
            or os.path.expanduser("~/.cache"), "sail", "search")
    os.makedirs(base, exist_ok=True)
    return base


def cache_enabled():
    """Caching is on unless asked off (SAIL_NO_CACHE=1 or a zero TTL)."""
    return not (os.environ.get("SAIL_NO_CACHE") == "1"
                or cache_ttl() <= 0)


def cache_ttl():
    try:
        return float(os.environ.get("SAIL_CACHE_TTL", CACHE_TTL))
    except ValueError:
        return CACHE_TTL


def _cache_path(source, query):
    digest = hashlib.sha1(f"{source}\0{query}".encode("utf-8")).hexdigest()
    return os.path.join(cache_dir(), f"{source}-{digest}.json")


def cache_read(source, query):
    """The cached answer for (source, query), or None on miss or expiry."""
    if not cache_enabled():
        return None
    try:
        with open(_cache_path(source, query), encoding="utf-8") as f:
            doc = json.load(f)
        results = doc["results"]
        saved = float(doc["saved"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if time.time() - saved > cache_ttl():
        return None
    return results


def cache_write(source, query, results):
    """Record a successful, non-empty answer — atomically, so a concurrent
    run never sees a half-written cache file. Failures and empty answers
    are deliberately not cached: a source that was down or returned thin
    must be retried, not pinned in place for the whole TTL."""
    if not results or not cache_enabled():
        return
    path = _cache_path(source, query)
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"saved": time.time(), "results": results}, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ---------------------------------------------------------------- search


def run_search(enabled, query):
    """(results, errors) from every enabled source, in parallel.

    Bounded by a global deadline (search_timeout). A source that still has
    not reported when the clock runs out is dropped and reported as
    unavailable, instead of setting the search time the way a hung socket
    would — urllib's timeout is per socket operation, and it walks every
    resolved address serially, so one stalled dual-stack host used to cost
    two full timeouts and, being the slowest enabled source, set the total.

    Plain daemon threads, not ThreadPoolExecutor: a pool's worker threads
    are joined at interpreter exit even after shutdown(wait=False), so a
    source abandoned at the deadline would keep holding up the search.py
    process afterwards — daemon threads are simply dropped, exactly the
    reasoning first_success applies at mirror scale.

    A fresh answer for (source, query) is also written to the cache, and a
    cached answer short-circuits the source entirely: no thread, no request.
    A source dropped by this run's deadline can therefore still have its
    late answer serve the next one."""
    results, errors = [], []
    if not enabled:
        return results, errors
    budget = search_timeout()
    deadline = time.monotonic() + budget
    pending = set(enabled)
    q = queue.Queue()

    def run(name, fn):
        try:
            out = fn(query) or []
            # cache before posting: the moment the queue releases this
            # answer, a follow-on search may already be reading the cache
            try:
                cache_write(name, query, out)
            except Exception:
                pass  # a cache problem must never fail the search
            q.put((name, out, None))
        except Exception as e:
            q.put((name, None, f"{name}: {e}"))

    for name in enabled:
        cached = cache_read(name, query)
        if cached is not None:
            results.extend(cached)
            pending.discard(name)
            continue
        threading.Thread(target=run, args=(name, ALL_SOURCES[name]),
                         daemon=True).start()

    while pending:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            name, out, err = q.get(timeout=remaining)
        except queue.Empty:
            break
        pending.discard(name)
        if err:
            errors.append(err)
        else:
            results.extend(out)

    for name in sorted(pending):
        errors.append(f"{name}: exceeded the {budget:g}s search deadline")
    return results, errors


def _field(value):
    """One safe TSV/display field: no tabs or line breaks."""
    return re.sub(r"[\t\r\n]", " ", str(value))


def to_rows(results):
    """Results as dicts with clean, printable strings."""
    rows = []
    for i, r in enumerate(results):
        rows.append({
            "id": str(i),
            "seeders": str(r["seeders"]),
            "size": _field(r["size"]),
            "source": _field(r["source"]),
            "title": _field(r["title"]),
            "age": _field(r.get("age", "?")),
            # a magnet carrying an encoded tab would otherwise split the row
            "magnet": re.sub(r"[\t\r\n]", "", str(r["magnet"])),
        })
    return rows


def to_tsv(rows):
    return "".join("\t".join(row[k] for k in
                             ("id", "seeders", "size", "source", "title",
                              "age", "magnet")) + "\n"
                   for row in rows)


def to_json(rows):
    return json.dumps(rows, indent=2, ensure_ascii=False)


def main():
    argv = sys.argv[1:]

    if argv and argv[0] == "--list-sources":
        for name in ALL_SOURCES:
            default = "1" if name in DEFAULT_ENABLED else "0"
            print(f"{name}\t{SOURCE_INFO[name]}\t{default}")
        return

    if argv and argv[0] == "--enabled":
        # single source of truth for the `sail sources` UI: the same
        # parsing, defaults, and "empty file means none" rule a search uses
        for name in load_enabled():
            print(name)
        return

    as_json = False
    if argv and argv[0] == "--json":
        as_json = True
        argv = argv[1:]

    unknown = []
    if argv and argv[0].startswith("--sources="):
        wanted = argv[0].split("=", 1)[1].split(",")
        enabled = [s for s in wanted if s in ALL_SOURCES]
        argv = argv[1:]
    else:
        enabled, unknown = read_config()

    if not argv or not " ".join(argv).strip():
        print("usage: search.py [--json] [--sources=a,b,c] <query>",
              file=sys.stderr)
        sys.exit(1)
    query = " ".join(argv).strip()

    # a typo'd or empty config must not read as "nothing matched your query"
    if unknown:
        print("[sources] ignoring unknown source name(s): "
              + ", ".join(unknown), file=sys.stderr)
    if not enabled:
        print("[sources] no sources enabled — run: sail sources",
              file=sys.stderr)
        sys.exit(3)

    results, errors = run_search(enabled, query)
    rows = to_rows(dedupe_sorted(filter_relevant(results, query)))

    if as_json:
        print(to_json(rows))
    else:
        sys.stdout.write(to_tsv(rows))

    # errors are printed even when other sources produced results: a caller
    # with SAIL_DEBUG=1 needs to see the broken scraper, not just a short
    # list. bin/sail shows only the [sources] summary line otherwise.
    for e in errors:
        print(f"  [source error] {e}", file=sys.stderr)
    if errors:
        print(f"[sources] {len(errors)} of {len(enabled)} unavailable",
              file=sys.stderr)

    # all sources failing is not "no results" — say so, and use a distinct
    # status so the caller can print the right hint
    if len(errors) == len(enabled):
        sys.exit(2)

    if not results and not as_json:
        print("No results found.", file=sys.stderr)


if __name__ == "__main__":
    main()
