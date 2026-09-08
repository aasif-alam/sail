# sail

Search, stream, and download torrents entirely from the macOS terminal.

## Usage

| Command | Behavior |
|---|---|
| `sail <query>` | pick a result, then choose stream/download |
| `sail -s <query>` | stream the picked result immediately |
| `sail -d <query>` | download the picked result immediately |
| `sail sources` | choose which sources every search uses |
| `sail --version` | print the installed version |

Downloads go to `~/Downloads/torrents` (override with `TORRENT_DOWNLOAD_DIR`).
Set `SAIL_DEBUG=1` to see each source's own errors (timeouts, parse
failures) after a search that comes back thin, and why a subtitle lookup
came back empty — normally both are discarded so a broken scraper or a
missing subtitle doesn't clutter the output.

When streaming a torrent with more than one video file (season packs,
movies with extras), sail shows a picker so you choose exactly which one
plays — only that file is downloaded, never the whole torrent. A single
video file plays immediately with no picker.

Streaming uses IINA, mpv, or VLC, whichever is found first (in that order).
While a stream plays, the terminal shows a live line of peers, download
speed, and progress for the file — quit the player to stop.

Set `SAIL_OPENSUBTITLES_KEY` to a free [OpenSubtitles API
key](https://www.opensubtitles.com/en/consumers) and sail looks up a
matching subtitle before each stream starts, downloading it fresh (nothing
is cached) and handing it to the player. `SAIL_SUB_LANG` picks the language
(default `en`). Without a key set, this is skipped entirely — streaming
works exactly as before. A macOS notification also fires when a background
download (`sail -d`) finishes or fails.

Nothing is cached: torrent metadata is fetched fresh on every stream, the
downloaded video lives in a temp directory that's wiped the moment you quit
the player, and any leftover data from a previous version of sail is
removed on startup.

Downloading (`sail -d`) uses the same picker: a season pack with several
video files lets you pick exactly which ones to save — tab toggles, ctrl-a
selects all, ctrl-d clears — and only the files you picked are written to
disk. A live progress line tracks the download the same way streaming does.

## Sources

Thirteen sources are built in. Pick and choose the ones every search uses:

```
sail sources
```

This opens a tick-list (tab toggles, enter saves). Your selection is stored in
`~/.config/sail/sources.conf` — one source name per line — and applies
globally. You can also edit that file by hand.

| Source | Focus | Method |
|---|---|---|
| `tpb` | general | JSON API |
| `yts` | movies | JSON API |
| `eztv` | TV episodes | JSON API |
| `knaben` | aggregator, well seeded | HTML scrape |
| `tcsv` | DHT crawled, open data | JSON API |
| `tq` | aggregator | HTML scrape |
| `et` | movies / general | HTML scrape |
| `solid` | general | JSON API |
| `nyaa` | anime / Asian media | HTML scrape |
| `1337x` | general | HTML scrape |
| `torlock` | general, verified | HTML scrape |
| `tgx` | general | HTML scrape |
| `lime` | general | HTML scrape |

With no config file, searches use `tpb`, `yts`, `eztv`, `knaben`, `tcsv`, and
`solid`.
Scraped sources depend on site layout and can break when sites change;
a failing source never blocks the others.

## Install

```bash
cd sail
./install.sh
```

The installer sets up everything via Homebrew: `fzf`, `webtorrent-cli`, the IINA
player, and the `sail` command itself.

## Uninstall

```bash
./uninstall.sh
```

## Shell completion

Tab-completion for the `-s`/`-d`/`sources`/`--version` flags lives in
`completions/`. Source the file for your shell, or drop it wherever your
shell auto-loads completions:

```bash
# zsh (e.g. Homebrew's site-functions dir, already on most fpaths)
cp completions/_sail "$(brew --prefix)/share/zsh/site-functions/_sail"

# bash (needs bash-completion)
cp completions/sail.bash "$(brew --prefix)/etc/bash_completion.d/sail"
```

`install.sh` copies both in automatically when it finds those directories.

## Development

```bash
python3 -m unittest discover tests
```

Tests mock all network calls — no live requests are made. A GitHub Actions
workflow ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs them
plus `shellcheck` on every push and PR.

## Notes

- Streaming needs a reasonably well-seeded torrent; rare files will stutter.
- Only download content you are legally permitted to obtain.
