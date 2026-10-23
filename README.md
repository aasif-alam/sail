# sail

Search, stream, and download torrents entirely from the macOS terminal.

## Usage

| Command | Behavior |
|---|---|
| `sail <query>` | pick a result, then choose stream/download |
| `sail -s <query>` | stream the picked result immediately |
| `sail -d <query>` | download the picked result immediately |
| `sail -l <query>` | list results (seeders, size, source, title) and exit |
| `sail --json <query>` | print results as a JSON array and exit |
| `sail --magnet <link>` | skip the search and use a magnet link directly |
| `sail sources` | choose which sources every search uses |
| `sail wlist [query]` | launch or manage the watchlist (save from results with ctrl-x) |
| `sail --version`, `sail -v` | print the installed version |
| `sail -h`, `sail --help` | show usage and exit |

Options may come before or after the query. `--` ends option parsing, so a
query starting with `-` is still searchable: `sail -- -movie`.

`sail -l` is pipe-friendly: it prints one row per result (`seeders`, `size`,
`source`, `title`) and sends the spinner and source warnings to stderr.
`sail --json` emits an array of objects with `id`, `seeders`, `size`,
`source`, `title`, `age`, and `magnet` (scraped sources may put a
`FETCH:<url>` detail-page marker in `magnet` until it is resolved). Their
exit statuses: `0` success, `1` no results (list mode), `2` every source
failed, `3` no sources enabled.

Downloads go to `~/Downloads/torrents` (override with `SAIL_DOWNLOAD_DIR`,
or the older `TORRENT_DOWNLOAD_DIR`; the former wins).

Set `SAIL_DEBUG=1` to see each source's own errors (timeouts, parse
failures) after a search that comes back thin, and why a subtitle already
in the torrent (if any) failed to fetch — normally both are discarded so
a broken scraper or a missing subtitle doesn't clutter the output.

A search races every enabled source in parallel and is bounded overall by
`SAIL_SEARCH_TIMEOUT` (default 6 seconds): a source that has not answered
by then is dropped for that search and reported unavailable, instead of
being allowed to define the search time. Repeating a query within
`SAIL_CACHE_TTL` (default 5 minutes) reuses the previous per-source
answers, so a near-instant rerun costs no traffic; `SAIL_NO_CACHE=1`
turns that off. Only successful, non-empty source answers are cached — a
source that failed or came back empty is retried next time.

When streaming a torrent with more than one video file (season packs,
movies with extras), sail shows a picker so you choose exactly which one
plays — only that file is downloaded, never the whole torrent. A single
video file plays immediately with no picker.

Streaming uses IINA, mpv, or VLC, whichever is found first (in that order).
Set `SAIL_PLAYER=iina`, `mpv`, or `vlc` to pick one; if it isn't installed
sail says so and falls back to the normal order.
While a stream plays, the terminal shows a live dashboard — progress bar,
download/upload speeds with a scrolling speed sparkline, ETA, ratio, and a
peer table listing each peer's client (qBittorrent, Transmission, …),
per-peer speeds, and how much of the torrent it has.
Quit the player to stop.

If the torrent itself includes a subtitle file for the video you picked
(scene releases for TV episodes often do), sail finds and streams it
alongside the video automatically — no external subtitle service, no API
key, no rate limit. It only attaches a subtitle it's confident matches: an exact filename
match, the same name plus a language suffix (English preferred when more
than one language is present), or — as a last resort — any subtitle file
in the same folder as the video. If nothing matches confidently, streaming
proceeds without one, silently unless `SAIL_DEBUG=1` is set.

A macOS notification fires when a download finishes or fails. Set `SAIL_NOTIFY=0` to turn notifications off.

Nothing is cached: torrent metadata is fetched fresh on every stream, the
downloaded video lives in a temp directory that's wiped the moment you quit
the player, and any leftover data from a previous version of sail is
removed on startup. Ctrl+C tears the renderer and any torrent/server child
down before exiting, so the next run doesn't collide with an orphaned
process.

Downloading (`sail -d`) uses the same picker: a season pack with several
video files lets you pick exactly which ones to save — tab toggles, ctrl-a
selects all, ctrl-d clears. Bytes are staged in a hidden
`.sail-partial-<pid>-*` directory inside the destination; only the files
you picked are moved into place once complete, so fragments of unselected
neighbours never litter the folder and an existing file is never deleted.
An interrupted download leaves only that hidden stage, which the next
download into the same folder removes. Make sure the destination has room
for the picked files (the stage is on the same filesystem, so the final
move is a rename, not a second copy). A live dashboard tracks progress the
same way streaming does.

If the swarm goes silent — no bytes for 300 seconds — sail stops with a
`stalled: no data received` error instead of hanging forever. Change the
timeout with `SAIL_STALL_TIMEOUT` (seconds; `0` disables the watchdog).
Metadata has a separate `SAIL_META_WAIT` (default 300 seconds) per attempt,
with one retry.

## Sources

Thirteen sources are built in. Pick and choose the ones every search uses:

```
sail sources
```

This opens a tick-list. Type source numbers to toggle them (for example
`1 3`), `a` turns all on, `x` turns all off, `s` saves, and `q` quits
without saving. Your selection is stored in `~/.config/sail/sources.conf` —
one source name per line — and applies globally. You can also edit that file
by hand; surrounding whitespace and `#` comments are allowed. A missing file
means the six defaults; a file that exists is authoritative, so saving an
empty list searches no sources. Saves are atomic, and a typo'd name is
reported (`[sources] ignoring unknown source name(s): …`) instead of
silently searching fewer sites.

| Source | Focus | Method |
|---|---|---|
| `tpb` | general | JSON API |
| `yts` | movies | JSON API |
| `eztv` | TV episodes | JSON API |
| `1337x` | general | HTML scrape |
| `knaben` | aggregator, well seeded | HTML scrape |
| `tcsv` | DHT crawled, open data | JSON API |
| `tq` | aggregator | HTML scrape |
| `et` | movies / general | HTML scrape |
| `solid` | general | JSON API |
| `nyaa` | anime / Asian media | HTML scrape |
| `torlock` | general, verified | HTML scrape |
| `tgx` | general | HTML scrape |
| `lime` | general | HTML scrape |

With no config file, searches use `tpb`, `yts`, `eztv`, `knaben`, `tcsv`, and
`solid`.
Scraped sources depend on site layout and can break when sites change;
a failing source never blocks the others. When some sources are down, sail
prints a one-line `[sources] N of M unavailable` summary; set
`SAIL_DEBUG=1` to see each failure.

## Results picker

The result list is sorted by seeders. Press `ctrl-t` to cycle the sort order
through seeders → size → newest; the header shows the current order. `ctrl-x`
saves the highlighted torrent to the watchlist and reopens the list, so you
can save several in one pass. Enter selects; esc cancels.

## Watchlist

Press `ctrl-x` on any search result to save it to the watchlist — the list
stays open so you can save several in one pass, and the header confirms each
save. `sail wlist` shows saved torrents: enter launches one straight to the
stream/download prompt (the search step is skipped entirely), `ctrl-x`
removes it, esc quits. An optional query narrows the list: `sail wlist dune`.

Entries live in `~/.config/sail/wlist.tsv` — title, magnet link, and the
date added, one per line, safe to edit by hand. Scraped results are stored
as a detail-page URL until they are saved, at which point sail resolves it
to a real magnet link — so a saved entry still launches long after it has
left the search results (if the page is down at save time, the unresolved
URL is kept and retried at launch). Re-adding a torrent moves it to the top
instead of duplicating it.

`cmd+x` would have read nicer, but terminals swallow it for their Edit
menu — CLI apps never see that keystroke — so the binding is `ctrl-x`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SAIL_DEBUG` | `0` | `1` prints per-source and subtitle errors |
| `SAIL_SOURCES` | `~/.config/sail/sources.conf` | source list path |
| `SAIL_WLIST` | `~/.config/sail/wlist.tsv` | watchlist path |
| `SAIL_DOWNLOAD_DIR` | `~/Downloads/torrents` | download destination |
| `TORRENT_DOWNLOAD_DIR` | — | older name for the destination; `SAIL_DOWNLOAD_DIR` wins |
| `SAIL_PLAYER` | auto (`iina`, `mpv`, `vlc`) | preferred player |
| `SAIL_NOTIFY` | `1` | `0` disables macOS notifications |
| `SAIL_META_WAIT` | `300` | seconds per metadata attempt |
| `SAIL_STALL_TIMEOUT` | `300` | seconds without data before giving up; `0` disables |
| `SAIL_SEARCH_TIMEOUT` | `6` | overall seconds one search may spend; a source still running when it expires is dropped and reported unavailable |
| `SAIL_NO_CACHE` | `0` | `1` disables the search-result cache |
| `SAIL_CACHE_TTL` | `300` | seconds a per-source search answer stays cached; `0` disables |
| `SAIL_CACHE_DIR` | `~/.cache/sail/search` | search-result cache location |
| `SAIL_WTMOD` | discovered | path to the webtorrent module (rarely needed) |
| `SAIL_UTF8_LOCALE` | `en_US.UTF-8` | locale used for multibyte-safe widths |

Paths accept a leading `~`. `NO_COLOR` disables color output.

## Install

Requires macOS. The one-liner — installs Homebrew if it's missing, then
everything else itself:

```bash
curl -fsSL https://raw.githubusercontent.com/aasif-alam/sail/main/install.sh | bash
```

To see every change first, pass `--dry-run` (it touches nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/aasif-alam/sail/main/install.sh | bash -s -- --dry-run
```

For a reproducible download, set `SAIL_REF` to a tag and verify it with
`SAIL_TARBALL_SHA256` (both apply to the piped installer):

```bash
curl -fsSL https://raw.githubusercontent.com/aasif-alam/sail/main/install.sh \
  | SAIL_REF=v1.5.0 SAIL_TARBALL_SHA256=<sha256> bash
```

Piping the installer from GitHub is trust-on-first-use; if you'd rather
inspect before executing, clone and run it directly — it behaves identically:

```bash
git clone https://github.com/aasif-alam/sail.git
cd sail
./install.sh
```

The installer sets up everything via Homebrew: `fzf`, `webtorrent-cli`, the IINA
player, and the `sail` command itself. It installs into a staging directory
and swaps it in only after a successful copy, so re-running it is the upgrade
path: an interrupted upgrade leaves the previous version working.
`./install.sh --dry-run` shows the plan without changing anything.

## Uninstall

```bash
./uninstall.sh            # removes sail, keeps your sources/watchlist
./uninstall.sh --purge    # also removes ~/.config/sail
```

Dependencies installed by Homebrew are left alone; the script prints the
command to remove them too.

## Shell completion

Tab-completion for the flags, `sources`, and `wlist` lives in `completions/`.
Source the file for your shell, or drop it wherever your shell auto-loads
completions:

```bash
# zsh (e.g. Homebrew's site-functions dir, already on most fpaths)
cp completions/_sail "$(brew --prefix)/share/zsh/site-functions/_sail"

# bash (needs bash-completion)
cp completions/sail.bash "$(brew --prefix)/etc/bash_completion.d/sail"
```

`install.sh` copies both in automatically when it finds those directories.

## Development

```bash
bash tests/run-all.sh
```

That runs the Python tests (every network call is mocked) and every shell
suite: watchlist storage and its lock, the tmux-driven pickers, `wt.js`
metadata and staged downloads, the sources UI, the download dashboard, CLI
exit statuses, and installer/uninstaller behavior. Individual suites are
`tests/test_*.sh`; `python3 -m unittest discover tests` runs only the Python
ones.

A GitHub Actions workflow ([.github/workflows/ci.yml](.github/workflows/ci.yml))
installs `tmux` and `webtorrent-cli`, then runs the whole suite on macOS.
A lint job runs `shellcheck -x` (sourced libraries included), `node --check`,
Python compilation plus `ruff` (`E4,E7,E9,F`), and `actionlint`. With `CI=1`,
a suite that would otherwise skip for a missing dependency fails instead.

## Notes

- Streaming needs a reasonably well-seeded torrent; rare files will stutter.
- webtorrent-cli 6.x ships webtorrent 2.8.5, which crashes on *every*
  torrent add when its `uint8-util` dependency resolves to 2.3+ (it passes
  the info-hash string to an API that now only accepts typed arrays; fixed
  upstream in webtorrent 3.x). sail checks for this at startup and repairs
  it in place — `lib/fix-webtorrent.sh` does the same standalone, and
  `brew reinstall webtorrent-cli` undoes the patch.
- Only download content you are legally permitted to obtain.
