#!/usr/bin/env bash
# dashboard.sh — the live torrent dashboard and its teardown.
#
# Sourced by bin/sail. Self-contained enough for the dashboard tests to
# source it on its own: colors and SPIN fall back to sane defaults when
# bin/sail has not defined them.
#
# Globals used: WORK (temp dir), DASH_H/BAR_W (may be preset), WT log at
# $WORK/wt.log. render_status runs as a background job; stop_render tears it
# down and erases the block exactly once.

: "${BLD:=}"; : "${DIM:=}"; : "${RED:=}"; : "${GRN:=}"
: "${YLW:=}"; : "${CYN:=}"; : "${RST:=}"
: "${DASH_H:=15}"
: "${BAR_W:=30}"
UTF8_LOCALE="${UTF8_LOCALE:-en_US.UTF-8}"
if [ -z "${SPIN+x}" ]; then
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
fi
# partial-block ramp for the progress bar's trailing cell (▏ is 1/8 of a
# cell wide … ▉ is 7/8; index = eighths of the current cell). dashboard.sh
# is sourced standalone by its tests, so it owns its copy.
PARTS=('' ▏ ▎ ▍ ▌ ▋ ▊ ▉)

# stop the dashboard renderer and clear its block. TERM first (it's usually
# mid-sleep, and bash only runs its cleanup trap once sleep returns), a
# short grace, then SIGKILL — so it can never redraw a frame after our
# cleanup. The renderer records the block height it actually drew in
# $WORK/render.h: a short terminal trims peer rows, and erasing the old
# fixed 15 would eat lines above the block.
stop_render() {
    [ -n "${RENDER_PID:-}" ] || return 0
    local pid="$RENDER_PID" h="${DASH_H:-15}"
    # clear the slot first: download mode calls stop_render explicitly and
    # the EXIT trap checks it again — a second stop would erase the done/
    # error lines printed in between
    RENDER_PID=""
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
    # reap it ourselves, else bash reports the SIGKILL as
    # "line NNN: PID Killed: 9 render_status ..." at the next prompt.
    # wait returns 137 after that SIGKILL; without || true, set -e would
    # abort here — before the block is cleared and before callers print
    wait "$pid" 2>/dev/null || true
    if [ -s "$WORK/render.h" ]; then
        h="$(cat "$WORK/render.h" 2>/dev/null || printf '%s' "$h")"
        case "$h" in ''|*[!0-9]*) h="${DASH_H:-15}" ;; esac
    fi
    if [ -f "$WORK/render.frame" ]; then
        printf '\033[%dA\033[J' "$h"
        rm -f "$WORK/render.frame"
    fi
    rm -f "$WORK/render.h"
    # restore the cursor even when the renderer died before its first frame
    printf '\033[?25h'
}

# multibyte-safe truncation — awk counts characters under a UTF-8 locale,
# while bash 3.2's ${s:0:n} counts bytes when no locale is set and would
# cut a Unicode char in half
cutw() {
    LC_ALL="$UTF8_LOCALE" awk -v w="$2" '{ s = $0
        if (length(s) > w) s = substr(s, 1, w - 1) "…"
        printf "%s", s }' <<< "$1" 2>/dev/null || printf '%s' "$1"
}

# speed samples as one space-separated string (KB/s) -> block-character
# sparkline. Takes the samples as $1, not stdin: a background job's stdin
# is /dev/null, so an awk-without-file here would silently print nothing.
# Block chars are split on "|" instead of sliced with substr, which is
# byte-based under the C locale and would mangle them — same reason the
# progress bar below is built char-by-char in bash
spark() {
    awk -v vals="$1" -v B='▁|▂|▃|▄|▅|▆|▇|█' 'BEGIN {
        n = split(B, ch, "|")
        max = 0
        m = split(vals, v, " ")
        for (i = 1; i <= m; i++) if ((v[i] + 0) > max) max = v[i] + 0
        out = ""
        for (i = 1; i <= m; i++) {
            lvl = max > 0 ? int((v[i] + 0) / max * (n - 1) + 0.5) : 0
            out = out ch[lvl + 1]
        }
        printf "%s", out
    }'
}

render_status() {  # $1 = STREAMING|DOWNLOADING   $2 = what's fetched   $3 = torrent title
    local mode="$1" what="$2" title="$3"
    local i=0 line peerline peers pct down total speed up upl eta ratio known
    local filled empty k chunk bar pc hist kb addr client d u have slot el
    local tw=118 peak hv hc rows slots last
    local ew rem dash_n dashfill tail_n tailfill
    SECONDS=0
    # fit the peer table to the terminal: 10 fixed lines around it (top rule,
    # 8 content rows, peer header, bottom rule), so a short window loses peer
    # rows instead of scrolling the dashboard
    rows="$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f1 || true)"
    slots=6
    case "$rows" in
        ''|*[!0-9]*) ;;
        *) slots=$((rows - 10))
           [ "$slots" -gt 6 ] && slots=6
           [ "$slots" -lt 1 ] && slots=1 ;;
    esac
    DASH_H=$((10 + slots))
    # stop_render quotes this back when erasing, so a resized window that
    # trimmed peer rows still clears exactly what was drawn
    printf '%s\n' "$DASH_H" > "$WORK/render.h"
    hist=$(printf '0 %.0s' $(seq 1 42))
    printf '\033[?25l'
    trap 'printf "\033[?25h"' TERM
    while :; do
        # one read of the log yields the newest STATUS + PEERS pair
        last="$( { tail -n 12 "$WORK/wt.log" 2>/dev/null || true; } \
            | awk 'index($0, "STATUS\t") == 1 { s = $0 }
                   index($0, "PEERS\t") == 1 { p = $0 }
                   END { printf "%s\n%s", s, p }' )"
        line="${last%%$'\n'*}"
        peerline="${last#*$'\n'}"
        peers=0 pct=0 down="0.0B" total="0.0B" speed="0.0B/s"
        up="0.0B/s" upl="0.0B" eta="∞" ratio="0.00" known=0
        case "$line" in
            STATUS*)
                IFS=$'\t' read -r _ peers pct down total speed up upl eta ratio known <<< "$line"
                ;;
        esac
        case "$pct"   in ''|*[!0-9]*) pct=0 ;;   esac
        case "$peers" in ''|*[!0-9]*) peers=0 ;; esac
        case "$known" in ''|*[!0-9]*) known=0 ;; esac

        # speed history — last 42 samples, converted to KB/s, for the sparkline
        kb="$(awk -v s="${speed%/s}" 'BEGIN{ v=s+0; u=s; sub(/^[0-9.]+/,"",u); m=(u~/^KB/)?1024:(u~/^MB/)?1048576:(u~/^GB/)?1073741824:1; printf "%.0f", v*m/1024 }')"
        hist="$(printf '%s' "$hist" | awk -v add="$kb" '{ for (i = 2; i <= NF; i++) printf "%s ", $i; printf "%s", add }')"
        # scale for the sparkline's dim peak label — max sample, back to human
        peak="$(printf '%s' "$hist" | awk '{ m = 0; for (i = 1; i <= NF; i++) if (($i + 0) > m) m = $i + 0; printf "%.1f", m * 1024 / 1048576 }')"
        # re-check the terminal width every ~5s: a window shrunk mid-run must
        # not wrap lines past the fixed dashboard height and smear the redraw.
        # stty size < /dev/tty, not tput cols — inside $( ) tput's stdout is
        # a pipe, so it can't ioctl the terminal and falls back to terminfo
        if [ $((i % 10)) -eq 0 ]; then
            c="$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2 || true)"
            case "$c" in
                ''|*[!0-9]*) ;;  # keep the last known width
                *) tw=$(awk -v c="$c" 'BEGIN{ w = 118
                        if (w > c - 2) w = c - 2
                        if (w < 20) w = 20
                        printf "%d", w }') ;;
            esac
        fi

        [ "$i" -gt 0 ] && printf '\033[%dA' "$DASH_H"
        # stop_render only erases a block that actually started: killing the
        # renderer before its first frame must not wipe unrelated output
        : > "$WORK/render.frame"
        # eighth-cell progress: pct scaled to BAR_W*8 so the remainder picks
        # a partial-block char — the bar moves in 1/8-cell steps instead of
        # 3.3% jumps, at the same width, from the same █░ family
        ew=$(( pct * BAR_W * 8 / 100 ))
        filled=$(( ew / 8 )); rem=$(( ew % 8 )); empty=$(( BAR_W - filled ))
        # built char-by-char in bash, not via `tr`: `tr` mangles multi-byte
        # UTF-8 under the C locale (the common default when a shell has no
        # LANG/LC_ALL set), turning the block characters into invalid garbage
        chunk=""; for ((k = 0; k < filled; k++)); do chunk+="█"; done
        bar="${GRN}${chunk}"
        if [ "$rem" -gt 0 ]; then
            bar+="${GRN}${PARTS[$((rem))]}"
            empty=$(( empty - 1 ))
        fi
        chunk=""; for ((k = 0; k < empty; k++)); do chunk+="░"; done
        bar+="${DIM}${chunk}${RST}"
        if [ "$peers" -eq 0 ]; then pc="$RED"
        elif [ "$peers" -lt 5 ]; then pc="$YLW"
        else pc="$GRN"; fi
        # 59s … 1h02m — hour form reads better than 62m13s on long downloads
        el="$((SECONDS / 3600))h$(printf '%02d' $((SECONDS % 3600 / 60)))m"
        [ "$SECONDS" -lt 3600 ] && el="$((SECONDS / 60))m$(printf '%02d' $((SECONDS % 60)))s"

        # torn-open frame ─ a top rule carrying mode + elapsed reads the
        # block as one object; the ╰ tail closes it. Both spans keep to
        # ASCII/box glyphs, so no wide-cell measuring is needed for the
        # edges (titles stay on their own lines inside)
        dash_n=$(( tw - 15 - ${#mode} ))
        [ "$dash_n" -lt 1 ] && dash_n=1
        printf -v dashfill '─%.0s' $(seq 1 "$dash_n")
        tail_n=$(( tw - 1 ))
        [ "$tail_n" -lt 1 ] && tail_n=1
        printf -v tailfill '─%.0s' $(seq 1 "$tail_n")
        printf '  ╭─ %s%s%s %s%s%s %s· %s ─%s\033[K\n' \
            "$CYN" "${SPIN[$((i % 10))]}" "$RST" \
            "$BLD" "$mode" "$RST" "$DIM" "$el" "$dashfill$RST"
        printf '  %s%s%s\033[K\n' "$BLD" "$(cutw "$title" "$tw")" "$RST"
        printf '  %s%s%s\033[K\n' "$DIM" "$(cutw "$what" "$tw")" "$RST"
        printf '  %s  %s%3s%%%s\033[K\n' "$bar" "$BLD" "$pct" "$RST"
        printf '  %s↓ %s%s   %s↑ %s%s   %sratio %s%s\033[K\n' \
            "$CYN" "$speed" "$RST" "$YLW" "$up" "$RST" "$DIM" "$ratio" "$RST"
        printf '  %s%s / %s downloaded   %s uploaded   %seta %s%s%s\033[K\n' \
            "$DIM" "$down" "$total" "$upl" "$RST" "$BLD" "$eta" "$RST"
        printf '  %s%s%s %speak %sMB/s%s\033[K\n' \
            "$CYN" "$(spark "$hist")" "$RST" "$DIM" "$peak" "$RST"
        printf '  %speers%s %s%s%s / %s%s known%s\033[K\n' \
            "$BLD" "$RST" "$pc" "$peers" "$RST" "$DIM" "$known" "$RST"
        if [ "$tw" -ge 90 ]; then
            printf '  %s%-21s %-16s %9s %9s  %6s%s\033[K\n' \
                "$DIM" ip client down up have% "$RST"
        elif [ "$tw" -ge 60 ]; then
            printf '  %s%-18s %9s %9s  %6s%s\033[K\n' \
                "$DIM" ip down up have% "$RST"
        else
            printf '  %s%9s %9s  %6s%s\033[K\n' \
                "$DIM" down up have% "$RST"
        fi
        slot=0
        if [ -n "$peerline" ]; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                IFS='|' read -r addr client d u have <<< "$p"
                slot=$((slot + 1))
                [ "$slot" -le "$slots" ] || break
                # seed maturity: full copy, partial, nothing yet
                hv="${have%%%}"
                case "$hv" in ''|*[!0-9]*) hv=0 ;; esac
                if [ "$hv" -ge 100 ]; then hc="$GRN"
                elif [ "$hv" -gt 0 ]; then hc="$YLW"
                else hc="$DIM"; fi
                if [ "$tw" -ge 90 ]; then
                    printf '  %-21s %s%-16s%s %9s %9s  %s%6s%s\033[K\n' \
                        "$(cutw "$addr" 21)" "$DIM" "$(cutw "$client" 16)" "$RST" "$d" "$u" "$hc" "$have" "$RST"
                elif [ "$tw" -ge 60 ]; then
                    printf '  %-18s %9s %9s  %s%6s%s\033[K\n' \
                        "$(cutw "$addr" 18)" "$d" "$u" "$hc" "$have" "$RST"
                else
                    printf '  %9s %9s  %s%6s%s\033[K\n' \
                        "$d" "$u" "$hc" "$have" "$RST"
                fi
            done <<< "$(printf '%s' "$peerline" | sed $'s/^PEERS\t//' | tr ';' '\n')"
        fi
        if [ "$slot" -eq 0 ] && [ "$peers" -eq 0 ]; then
            # dead first seconds made the dashboard look stuck — say why
            printf '  %scontacting swarm…%s\033[K\n' "$DIM" "$RST"
            slot=1
        fi
        while [ "$slot" -lt "$slots" ]; do
            slot=$((slot + 1))
            printf '\033[K\n'
        done
        printf '  %s╰%s%s\033[K\n' "$DIM" "$tailfill" "$RST"
        i=$((i + 1))
        sleep 0.5
    done
}
