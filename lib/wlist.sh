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
    local f="${SAIL_WLIST:-$HOME/.config/sail/wlist.tsv}"
    if [ "$f" = "~" ]; then
        f="$HOME"
    elif [ "${f#\~/}" != "$f" ]; then
        f="$HOME/${f#\~/}"
    fi
    printf '%s' "$f"
}

# Serialize writers: two terminals (or a save racing a remove) previously
# rewrote the same file through the same .tmp.$$ name and could clobber each
# other. mkdir is atomic on every filesystem sail supports. A lock left by a
# crashed writer is stolen only after it is a minute old.
wlist_lock() {
    local f lock i=0
    f="$(wlist_file)"
    mkdir -p "$(dirname "$f")"
    lock="$f.lock"
    while ! mkdir "$lock" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 50 ]; then
            # steal a lock left by a crashed writer once it is a minute old
            if find "$lock" -maxdepth 0 -mmin +1 -print -quit 2>/dev/null \
               | grep -q .; then
                rmdir "$lock" 2>/dev/null || true
                i=0
                continue
            fi
            # a live writer holds this for milliseconds; never hang the UI
            # (also avoids a spin when the config dir is read-only)
            WLIST_LOCK=""
            return 0
        fi
        sleep 0.1
    done
    WLIST_LOCK="$lock"
}

wlist_unlock() {
    if [ -n "${WLIST_LOCK:-}" ]; then
        rmdir "$WLIST_LOCK" 2>/dev/null || true
    fi
    WLIST_LOCK=""
}

# btih info hash for dedup, extracted with bash's own regex — the dedup
# loops in wlist_add/wlist_remove run this once per stored row, and the old
# printf|sed|tr pipeline cost ~3 subprocesses per row (a 200-row watchlist
# paid ~0.9s per save). Sets WLIST_KEY instead of printing so those loops
# need no $( ) subshell per row either. bash-3.2 notes: the regex lives in
# a variable because 3.2 treats quoted characters in a [[ =~ ]] pattern as
# literals, and ${var,,} lowercasing is 4.0+ — hence the per-letter
# expansions (hex digits only, so six of them cover it).
WLIST_BTIH_RE='[?&]xt=urn:btih:([0-9A-Fa-f]{32,})'
_wlist_key_of() {  # $1 = magnet -> sets WLIST_KEY
    WLIST_KEY="$1"
    if [[ "$1" =~ $WLIST_BTIH_RE ]]; then
        WLIST_KEY="${BASH_REMATCH[1]}"
        WLIST_KEY="${WLIST_KEY//A/a}"; WLIST_KEY="${WLIST_KEY//B/b}"
        WLIST_KEY="${WLIST_KEY//C/c}"; WLIST_KEY="${WLIST_KEY//D/d}"
        WLIST_KEY="${WLIST_KEY//E/e}"; WLIST_KEY="${WLIST_KEY//F/f}"
    fi
}

# dedup key: the btih info hash if the magnet has one, else the whole string
wlist_key() {
    _wlist_key_of "$1"
    printf '%s' "$WLIST_KEY"
}

# wlist_add <title> <magnet>
#   returns 0 = added new, 1 = already present (bumped to newest), 2 = bad args
wlist_add() {
    local title="$1" magnet="$2" key f tmp now found=0 t="" m="" ts=""
    title="${title//$'\t'/ }"; title="${title//$'\n'/ }"; title="${title//$'\r'/ }"
    title="${title#"${title%%[![:space:]]*}"}"   # ltrim
    title="${title%"${title##*[![:space:]]}"}"   # rtrim
    [ -n "$title" ] && [ -n "$magnet" ] || return 2
    _wlist_key_of "$magnet"; key="$WLIST_KEY"
    f="$(wlist_file)"
    wlist_lock
    touch "$f"
    tmp="$f.tmp.$$"
    now="$(date +%s)"
    # one redirect for the whole rewrite — reopening the temp file with >>
    # per surviving row cost a file open per row; the loop body itself is
    # pure bash (see _wlist_key_of), so no subprocesses per row anywhere
    {
        while IFS=$'\t' read -r t m ts || [ -n "$t" ]; do
            [ -n "$t" ] || continue
            # drop any existing row for this torrent — it's re-appended below
            # with a fresh timestamp, which is what bumps it to newest
            _wlist_key_of "$m"
            if [ "$WLIST_KEY" = "$key" ]; then
                found=1
                continue
            fi
            printf '%s\t%s\t%s\n' "$t" "$m" "$ts"
        done < "$f"
        printf '%s\t%s\t%s\n' "$title" "$magnet" "$now"
    } > "$tmp"
    mv "$tmp" "$f"
    wlist_unlock
    return "$found"
}

# wlist_remove <magnet> — drops the entry matching that magnet's key
#   returns 0 = removed, 1 = no such entry
wlist_remove() {
    local key f tmp removed=0 t="" m="" ts=""
    [ -n "$1" ] || return 1
    _wlist_key_of "$1"; key="$WLIST_KEY"
    f="$(wlist_file)"
    wlist_lock
    if [ ! -f "$f" ]; then
        wlist_unlock
        return 1
    fi
    tmp="$f.tmp.$$"
    {
        while IFS=$'\t' read -r t m ts || [ -n "$t" ]; do
            [ -n "$t" ] || continue
            _wlist_key_of "$m"
            if [ "$WLIST_KEY" = "$key" ]; then
                removed=1
                continue
            fi
            printf '%s\t%s\t%s\n' "$t" "$m" "$ts"
        done < "$f"
    } > "$tmp"
    mv "$tmp" "$f"
    wlist_unlock
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
