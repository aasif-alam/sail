#!/usr/bin/env bash
# wlist.sh — watchlist storage for sail. Sourced by bin/sail; the fzf UI
# lives there, everything here is plain storage so tests/test_wlist.sh can
# exercise it without a terminal. SAIL_WLIST overrides the store location
# (mirrors SAIL_SOURCES for sources.conf).
#
# Storage: TSV, one entry per line — title<TAB>magnet<TAB>added_epoch.
# New entries are appended (newest last); the wlist UI displays newest
# first. Entries are deduped by btih info hash when the magnet carries one,
# otherwise by the exact magnet string (FETCH: urls from scraped sources
# have no hash until they're resolved at launch time). Re-adding an entry
# moves it to newest and refreshes its title — stale rows drift upward and
# out instead of accumulating duplicates.
#
# All functions are bash-3.2 safe (macOS stock /bin/bash) and avoid arrays
# — see the array-avoidance note in bin/sail's pick_video.

wlist_file() {
    printf '%s' "${SAIL_WLIST:-$HOME/.config/sail/wlist.tsv}"
}

# dedup key: the btih info hash if the magnet has one, else the whole string
wlist_key() {
    local h
    h="$(printf '%s' "$1" \
        | sed -n 's/.*[?&]xt=urn:btih:\([0-9A-Fa-f]\{32,\}\).*/\1/p' \
        | tr 'A-F' 'a-f')"
    if [ -n "$h" ]; then printf '%s' "$h"; else printf '%s' "$1"; fi
}

# wlist_add <title> <magnet>
#   returns 0 = added new, 1 = already present (bumped to newest), 2 = bad args
wlist_add() {
    local title="$1" magnet="$2" key f tmp now found=0 t="" m="" ts=""
    title="${title//$'\t'/ }"; title="${title//$'\n'/ }"; title="${title//$'\r'/ }"
    title="${title#"${title%%[![:space:]]*}"}"   # ltrim
    title="${title%"${title##*[![:space:]]}"}"   # rtrim
    [ -n "$title" ] && [ -n "$magnet" ] || return 2
    key="$(wlist_key "$magnet")"
    f="$(wlist_file)"
    mkdir -p "$(dirname "$f")"
    touch "$f"
    tmp="$f.tmp.$$"
    : > "$tmp"
    while IFS=$'\t' read -r t m ts || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        # drop any existing row for this torrent — it's re-appended below
        # with a fresh timestamp, which is what bumps it to newest
        if [ "$(wlist_key "$m")" = "$key" ]; then
            found=1
            continue
        fi
        printf '%s\t%s\t%s\n' "$t" "$m" "$ts" >> "$tmp"
    done < "$f"
    now="$(date +%s)"
    printf '%s\t%s\t%s\n' "$title" "$magnet" "$now" >> "$tmp"
    mv "$tmp" "$f"
    return "$found"
}

# wlist_remove <magnet> — drops the entry matching that magnet's key
#   returns 0 = removed, 1 = no such entry
wlist_remove() {
    local key f tmp removed=0 t="" m="" ts=""
    [ -n "$1" ] || return 1
    key="$(wlist_key "$1")"
    f="$(wlist_file)"
    [ -f "$f" ] || return 1
    tmp="$f.tmp.$$"
    : > "$tmp"
    while IFS=$'\t' read -r t m ts || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        if [ "$(wlist_key "$m")" = "$key" ]; then
            removed=1
            continue
        fi
        printf '%s\t%s\t%s\n' "$t" "$m" "$ts" >> "$tmp"
    done < "$f"
    mv "$tmp" "$f"
    [ "$removed" -eq 1 ]
}

# wlist_lookup <rows-file> <id> — print "title<TAB>magnet" for a row of the
# render snapshot the wlist UI keeps in its temp dir (id = 1-based line
# number; rows carry title<TAB>magnet<TAB>added, the display row's leading
# number is that line number)
wlist_lookup() {
    awk -F'\t' -v id="$2" 'NR == id { print $1 "\t" $2; found = 1; exit }
        END { if (!found) exit 1 }' "$1"
}
