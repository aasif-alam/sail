#!/usr/bin/env bash
# wlist-ui.sh — the `sail wlist [query]` picker.
#
# Sourced by bin/sail (wlist storage lives in lib/wlist.sh). Sets SEL_TITLE
# and MAGNET for the caller when an entry is launched; returns 1 when the
# list is empty or the user quits. Globals used: WORK, BLD, DIM, RST.

sail_wlist_ui() {
    local WQUERY="$1" NOTICE="" ROWS OUT PICK_KEY LINE PLAIN WID WLOOK
    local WTITLE WMAGNET

    if [ ! -s "$(wlist_file)" ]; then
        printf '  watchlist is empty — search something and press %sctrl-x%s to add it\n' \
            "$BLD" "$RST"
        return 1
    fi

    while :; do
        cp "$(wlist_file)" "$WORK/wlist_rows"
        # display newest first (the file stores newest last); the leading
        # number is the row's line number in wlist_rows, which
        # wlist_lookup turns back into title + magnet at launch time.
        # now comes in via -v because macOS's stock awk has no systime()
        ROWS="$(awk -F'\t' -v D="$DIM" -v B="$BLD" -v R="$RST" -v now="$(date +%s)" '
            function agestr(s,   d) {
                d = now - s; if (d < 0) d = 0
                if (d < 60)      return "just now"
                if (d < 3600)    return int(d / 60) "m ago"
                if (d < 86400)   return int(d / 3600) "h ago"
                if (d < 2592000) return int(d / 86400) "d ago"
                return int(d / 2592000) "mo ago"
            }
            { printf "%d\t%s%-9s%s %s%s%s\n", NR, D, agestr($3), R, B, $1, R }' \
            "$WORK/wlist_rows" | sort -t "$(printf '\t')" -k1,1nr)"
        if [ -z "$ROWS" ]; then
            printf '  watchlist is empty\n'
            return 1
        fi
        OUT="$(printf '%s\n' "$ROWS" | fzf --ansi --expect=ctrl-x \
              --delimiter='\t' --with-nth=2,3 \
              --query="$WQUERY" \
              --header="saved     title"$'\n'"  enter: launch   ctrl-x: remove   esc: quit$NOTICE" \
              --header-first --reverse --height=90% --tabstop=1 \
              --border=rounded --margin=1,2)" || return 1
        PICK_KEY="${OUT%%$'\n'*}"
        LINE="$(printf '%s' "$OUT" | sed -n '2p')"
        PLAIN="$(printf '%s' "$LINE" | sed $'s/\x1b\\[[0-9;]*m//g')"
        WID="$(printf '%s\n' "$PLAIN" | cut -f1)"
        WLOOK="$(wlist_lookup "$WORK/wlist_rows" "$WID" || true)"
        WTITLE="${WLOOK%%$'\t'*}"
        WMAGNET="${WLOOK#*$'\t'}"
        if [ "$PICK_KEY" = "ctrl-x" ] && [ -n "$WTITLE" ]; then
            if wlist_remove "$WMAGNET"; then
                NOTICE=$'\n\n'"  removed from watchlist: $WTITLE"
            else
                NOTICE=$'\n\n'"  couldn't remove: $WTITLE"
            fi
            continue
        fi
        break
    done

    [ -n "$WTITLE" ] && [ -n "$WMAGNET" ] || return 1
    # shellcheck disable=SC2034  # both are read by bin/sail
    SEL_TITLE="$WTITLE"
    # shellcheck disable=SC2034
    MAGNET="$WMAGNET"
    return 0
}
