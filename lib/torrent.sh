#!/usr/bin/env bash
# torrent.sh — metadata, file pickers, streaming, and downloading.
#
# Sourced by bin/sail after lib/dashboard.sh and lib/wtdir.sh. Globals it
# expects from the caller: WORK, LIB_DIR, WTMOD, SPIN, SAIL_DEBUG,
# the palette variables, and (for downloads) the destination directory.
#
# Everything long-running runs as a background child whose pid is kept in a
# global (WPID/WT_PID/RENDER_PID) so bin/sail's EXIT trap can tear it down.

# ---- metadata -------------------------------------------------------------

# sail_read_meta <torrent-id>
#   pulls the .torrent + file list into $WORK, sets META to the .torrent path
#   (empty on failure). files.tsv is the success signal: wt.js writes it last
#   via rename, so a killed attempt can never look like a complete one.
sail_read_meta() {
    local magnet="$1" meta_try i wait_s
    META=""
    wait_s="${SAIL_META_WAIT:-300}"
    case "$wait_s" in ''|*[!0-9]*) wait_s=300 ;; esac

    printf '  reading torrent info '
    if [ -n "$WTMOD" ]; then
        for meta_try in 1 2; do
            node "$LIB_DIR/wt.js" "$WTMOD" meta "$magnet" "$WORK" \
                >"$WORK/meta.log" 2>&1 &
            WPID=$!
            i=0
            while kill -0 "$WPID" 2>/dev/null; do
                [ "$i" -ge $((wait_s * 2)) ] && break
                if [ -t 1 ]; then
                    printf '%s%s%s\b' "$CYN" "${SPIN[$((i % 10))]}" "$RST"
                fi
                i=$((i + 1)); sleep 0.5
            done
            stop_pid "$WPID"
            WPID=""
            if [ -t 1 ]; then printf '\r\033[K'; fi
            if [ -s "$WORK/files.tsv" ]; then
                META="$(find "$WORK" -maxdepth 1 -name '*.torrent' -print -quit)"
                break
            fi
            META=""
            if [ "$meta_try" != 2 ] && [ -t 1 ]; then
                printf '  %sno peers yet — retrying%s ' "$DIM" "$RST"
            fi
        done
    fi
    printf '\n'
    if [ -z "$META" ] && [ "${SAIL_DEBUG:-0}" = 1 ] && [ -s "$WORK/meta.log" ]; then
        printf '  %smeta debug:%s\n' "$DIM" "$RST" >&2
        sed 's/^/    /' "$WORK/meta.log" >&2
    fi
}

# list the video files in $WORK/files.tsv: sets VIDS and N_VIDS
sail_videos() {
    VIDS=""
    if [ -s "$WORK/files.tsv" ]; then
        VIDS="$(awk -F'\t' 'tolower($3) ~ /\.(mkv|mp4|avi|mov|webm|m4v|mpg|mpeg|wmv|flv|ts|m2ts|vob)$/' "$WORK/files.tsv")"
    fi
    N_VIDS="$(printf '%s\n' "$VIDS" | { grep -c . || true; })"
}

# true when the file list is usable and selective download is available
sail_can_serve() {
    [ -s "$WORK/files.tsv" ] && [ "${N_VIDS:-0}" -gt 0 ] && [ -n "$WTMOD" ]
}

# ---- file picker ----------------------------------------------------------

# pick_video "$VIDS"        -> single-select (stream mode)
# pick_video "$VIDS" multi  -> multi-select, tab toggles, ctrl-a/ctrl-d
pick_video() {
    # a plain string, not an array: bash 3.2 (macOS's stock /bin/bash) throws
    # "unbound variable" under `set -u` when expanding an empty array with
    # "${arr[@]}" — an empty scalar string has no such problem
    local sorted common_dir fzf_extra="" header
    if [ "${2:-}" = "multi" ]; then
        fzf_extra="--multi --bind ctrl-a:select-all,ctrl-d:deselect-all"
        header="size      ep      file"$'\n'"${DIM}$(printf '─%.0s' $(seq 1 48))${RST}"$'\n'"  tab toggles · ctrl-a all · ctrl-d none · enter confirms"
    else
        header="size      ep      file"$'\n'"${DIM}$(printf '─%.0s' $(seq 1 48))${RST}"$'\n'"  enter: play   esc: cancel"
    fi
    # sort by path, not raw torrent-file index: scene releases zero-pad
    # episode numbers (S01E01, S01E10, ...), so alphabetical order is
    # already the right watch order — the torrent's own file order isn't
    sorted="$(printf '%s\n' "$1" | sort -t "$(printf '\t')" -k3)"
    # if every file lives in the same folder (any season pack), show it
    # once above the list instead of repeating it on every row
    common_dir="$(printf '%s\n' "$sorted" | awk -F'\t' '{ d=$3; sub(/[^\/]*$/, "", d); print d }' | sort -u)"
    if [ "$(printf '%s\n' "$common_dir" | grep -c .)" -ne 1 ]; then
        common_dir=""
    fi
    # >&2, not stdout: the caller captures this function's stdout as the
    # picked line(s) via $(...) — anything else printed to stdout here would
    # get parsed as a bogus extra "selection"
    [ -n "$common_dir" ] && printf '  %sin %s%s\n\n' "$DIM" "$common_dir" "$RST" >&2
    # fzf_extra below is deliberately unquoted: it's a fixed, controlled
    # string (not user input) that must word-split into separate fzf
    # flags — see the array-avoidance comment near the top of this function
    # shellcheck disable=SC2086
    printf '%s\n' "$sorted" | awk -F'\t' -v D="$DIM" -v B="$BLD" -v R="$RST" \
        -v G="$GRN" -v Y="$YLW" -v Rd="$RED" -v CD="$common_dir" '
        function tobytes(s,   n, u) {
            u = substr(s, length(s) - 1, 2)
            if (u == "KB") return (substr(s, 1, length(s) - 2) + 0) * 1024
            if (u == "MB") return (substr(s, 1, length(s) - 2) + 0) * 1024 ^ 2
            if (u == "GB") return (substr(s, 1, length(s) - 2) + 0) * 1024 ^ 3
            if (u == "TB") return (substr(s, 1, length(s) - 2) + 0) * 1024 ^ 4
            return (substr(s, 1, length(s) - 1) + 0)
        }
        {
            bytes = tobytes($2)
            if (bytes >= 150 * 1024 ^ 2)      sc = G
            else if (bytes >= 20 * 1024 ^ 2)  sc = Y
            else                              sc = Rd

            n = split($3, parts, "/")
            fname = parts[n]
            dir = ""
            if (CD == "") for (k = 1; k < n; k++) dir = dir parts[k] "/"

            # pull the episode tag (S01E07, s1e7, ...) out of the path so
            # it reads as its own glanceable column instead of forcing a
            # scan through an otherwise-identical release-name filename
            tag = ""
            if (match($3, /[Ss][0-9][0-9]?[Ee][0-9][0-9]?[0-9]?/))
                tag = toupper(substr($3, RSTART, RLENGTH))

            sizecol = sprintf("%s%-9s%s", sc, $2, R)
            if (tag != "") {
                tagcol  = sprintf("%s%-7s%s", B, tag, R)
                pathcol = sprintf("%s%s%s%s", D, dir, fname, R)
            } else {
                tagcol  = sprintf("%-7s", "")
                pathcol = sprintf("%s%s%s%s%s%s", D, dir, R, B, fname, R)
            }
            printf "%s\t%s\t%s\t%s\n", $1, sizecol, tagcol, pathcol
        }' \
    | fzf --ansi --reverse --height=80% --border=rounded --margin=1,2 \
          --delimiter='\t' --with-nth=2,3,4 \
          $fzf_extra \
          --header="$header" \
          --header-first
}

# pick one video for streaming; sets VID_IDX. returns 1 when cancelled.
sail_pick_stream_file() {
    local picked
    if [ "$N_VIDS" -eq 1 ]; then
        VID_IDX="$(printf '%s' "$VIDS" | cut -f1)"
    else
        printf '  %smultiple video files — pick one%s\n\n' "$BLD" "$RST"
        picked="$(pick_video "$VIDS")"
        [ -n "$picked" ] || return 1
        VID_IDX="$(printf '%s\n' "$picked" | sed $'s/\x1b\\[[0-9;]*m//g' | grep -E '^[0-9]+\t' | cut -f1 | tr -d ' ')"
        [ -n "$VID_IDX" ] || return 1
    fi
    return 0
}

# pick one or more videos for downloading; sets SEL_IDXS and N_SEL.
# returns 1 when cancelled.
sail_pick_download_files() {
    local picked
    if [ "$N_VIDS" -eq 1 ]; then
        SEL_IDXS="$(printf '%s' "$VIDS" | cut -f1)"
    else
        printf '  %spick episodes to download%s\n\n' "$BLD" "$RST"
        picked="$(pick_video "$VIDS" multi)"
        [ -n "$picked" ] || return 1
        SEL_IDXS="$(printf '%s\n' "$picked" | sed $'s/\x1b\\[[0-9;]*m//g' | grep -E '^[0-9]+\t' | cut -f1 | tr -d ' ' | paste -sd, -)"
        [ -n "$SEL_IDXS" ] || return 1
    fi
    N_SEL=$(( $(printf '%s' "$SEL_IDXS" | tr -cd ',' | wc -c) + 1 ))
    return 0
}

# ---- player ---------------------------------------------------------------

# choose a player, honoring SAIL_PLAYER. sets PLAYER and IINA_CLI.
sail_player() {
    local want="${SAIL_PLAYER:-}"
    local iina_bin="/Applications/IINA.app/Contents/MacOS/iina-cli"

    iina_cli() {
        command -v iina-cli 2>/dev/null || printf '%s' "$iina_bin"
    }

    case "$want" in
        ""|iina|mpv|vlc) ;;
        *) printf '  ignoring SAIL_PLAYER=%s (use iina, mpv or vlc)\n' \
               "$want" >&2
           want="" ;;
    esac

    if [ -n "$want" ]; then
        case "$want" in
            iina) if [ -x "$iina_bin" ] || command -v iina-cli >/dev/null 2>&1; then
                      PLAYER="iina"; IINA_CLI="$(iina_cli)"; return 0
                  fi ;;
            mpv)  if command -v mpv >/dev/null 2>&1; then
                      PLAYER="mpv"; return 0
                  fi ;;
            vlc)  if command -v vlc >/dev/null 2>&1; then
                      PLAYER="vlc"; return 0
                  fi ;;
        esac
        printf '  SAIL_PLAYER=%s not found — falling back\n' "$want" >&2
    fi

    if [ -x "$iina_bin" ] || command -v iina-cli >/dev/null 2>&1; then
        PLAYER="iina"; IINA_CLI="$(iina_cli)"; return 0
    elif command -v mpv >/dev/null 2>&1; then
        PLAYER="mpv"; return 0
    elif command -v vlc >/dev/null 2>&1; then
        PLAYER="vlc"; return 0
    fi
    return 1
}

# ---- folder picker --------------------------------------------------------

# sail_pick_folder <default> — print the chosen directory (no trailing /),
# or nothing when cancelled. The path travels as argv, not inside the
# AppleScript source: a quote or backslash in a folder name must not turn
# into script syntax.
sail_pick_folder() {
    osascript - "$1" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
    set theFolder to POSIX file (item 1 of argv)
    set chosen to choose folder with prompt "Download folder:" default location theFolder
    return POSIX path of chosen
end run
APPLESCRIPT
}

# ---- streaming ------------------------------------------------------------

# wait for the webtorrent http server and find its real port: the
# process also opens a bittorrent wire socket that accepts connections
# without ever speaking http, so probe each listening port with a
# request for /webtorrent/favicon.ico (answers 404 as soon as the
# server is up — no data needed)
wait_stream_port() {
    local pid="$1" i p code ports
    for i in $(seq 1 30); do
        ports="$(lsof -nP -p "$pid" -a -iTCP -sTCP:LISTEN 2>/dev/null \
            | awk '/LISTEN/{gsub(".*:", "", $9); print $9}' | sort -u)"
        for p in $ports; do
            code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' \
                "http://127.0.0.1:$p/webtorrent/favicon.ico" 2>/dev/null || true)"
            if [ "$code" != "000" ] && [ -n "$code" ]; then
                printf '%s' "$p"
                return 0
            fi
        done
        sleep 0.5
    done
    return 1
}

# sail_stream <magnet> <meta-path> <title>
sail_stream() {
    local magnet="$1" meta="$2" title="$3"
    local vid_idx vid_path sub_match sub_idx sub_torrent_path sub_path=""
    local serve_sel infohash urlpath sub_urlpath sub_basename port="" rc=0
    local stream_url i

    if ! sail_player; then
        printf '  no supported player found (iina / mpv / vlc)\n' >&2
        return 1
    fi

    FALLBACK_STREAM() {
        printf '  %s%s%s\n\n' "$YLW" "$1" "$RST"
        webtorrent "$magnet" "--$PLAYER" -i
    }

    if ! sail_can_serve; then
        FALLBACK_STREAM "couldn't read the file list — falling back to webtorrent's picker"
        return $?
    fi

    sail_pick_stream_file || return 0
    vid_idx="$VID_IDX"
    vid_path="$(awk -F'\t' -v i="$vid_idx" '$1 == i {print $3}' "$WORK/files.tsv")"

    # look for a subtitle already inside this torrent that matches the
    # picked video — free, no rate limit, and guaranteed to be timed for
    # this exact release, unlike an external subtitle API. Exact filename
    # match beats "same stem plus a language suffix" beats "just in the
    # same folder"; anything scoring 0 (no candidate at all) is skipped
    # rather than guessing and attaching the wrong episode's subtitle
    sub_match="$(awk -F'\t' -v vidpath="$vid_path" '
        BEGIN {
            dir = vidpath; sub(/[^\/]*$/, "", dir); dir = tolower(dir)
            base = vidpath; sub(/.*\//, "", base)
            stem = base; sub(/\.[^.]*$/, "", stem); stem = tolower(stem)
        }
        {
            path = $3; lc = tolower(path)
            if (lc !~ /\.(srt|ass|ssa|vtt)$/) next
            cbase = path; sub(/.*\//, "", cbase)
            cstem = cbase; sub(/\.[^.]*$/, "", cstem); cstem = tolower(cstem)
            cdir = path; sub(/[^\/]*$/, "", cdir); cdir = tolower(cdir)
            score = 0
            if (cstem == stem) score = 3
            else if (index(cstem, stem) == 1) score = 2
            else if (cdir == dir) score = 1
            if (score == 0) next
            bonus = (cstem ~ /(^|[._-])(en|eng|english)([._-]|$)/) ? 1 : 0
            total = score * 10 + bonus
            if (total > best) { best = total; bi = $1; bp = path }
        }
        END { if (bi != "") printf "%s\t%s\n", bi, bp }
    ' "$WORK/files.tsv")"
    sub_idx="" sub_torrent_path=""
    if [ -n "$sub_match" ]; then
        sub_idx="${sub_match%%$'\t'*}"
        sub_torrent_path="${sub_match#*$'\t'}"
    fi
    serve_sel="$vid_idx"
    [ -n "$sub_idx" ] && serve_sel="$vid_idx,$sub_idx"

    # run a quiet wt.js stream server and launch the player ourselves:
    # webtorrent's own --iina opens IINA via URL scheme, which doesn't give
    # us a way to know when playback ends (needed to clean up the temp dir),
    # so we drive both the server and the player directly for one
    # consistent, controllable launch path
    # the meta phase names the .torrent file after the info hash, so the
    # hash is right there in $meta's basename — no json parse, no python
    infohash="${meta##*/}"
    infohash="${infohash%.torrent}"
    urlpath="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$vid_path")"
    node "$LIB_DIR/wt.js" "$WTMOD" serve "$meta" "$WORK/stream" \
        "$serve_sel" "$OPTS_JSON" 0 >"$WORK/wt.log" 2>&1 &
    WT_PID=$!
    # the runner prints PORT=<n> once listening (falls back to any free port
    # if our requested one was taken); verify it actually serves http
    for i in $(seq 1 40); do
        port="$(sed -n 's/^PORT=//p' "$WORK/wt.log" 2>/dev/null | head -1)"
        [ -n "$port" ] && break
        kill -0 "$WT_PID" 2>/dev/null || break
        sleep 0.25
    done
    if [ -z "$port" ]; then
        port="$(wait_stream_port "$WT_PID" || true)"
    fi
    if [ -z "$port" ]; then
        FALLBACK_STREAM "stream server didn't start ($(tail -2 "$WORK/wt.log" 2>/dev/null | tr '\n' ' ')) — falling back to webtorrent's picker"
        return $?
    fi
    stream_url="http://127.0.0.1:$port/webtorrent/$infohash/$urlpath"

    # the subtitle is served the same way as the video — pull it from our
    # own stream server (which pulls it from the swarm, prioritized by the
    # select() call in wt.js) rather than an external service. It's tiny,
    # so this is normally near-instant; capped so a slow swarm can never
    # hold up playback for long
    if [ -n "$sub_idx" ]; then
        sub_urlpath="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$sub_torrent_path")"
        # keep the original torrent filename locally too — a generic name
        # like "sub.srt" is what IINA's subtitle picker would then show,
        # which is indistinguishable from an unrelated or empty file at a
        # glance; the real name makes it obviously the right one
        sub_basename="$(basename "$sub_torrent_path")"
        if curl -fsS -m 8 -o "$WORK/$sub_basename" \
                "http://127.0.0.1:$port/webtorrent/$infohash/$sub_urlpath" 2>"$WORK/subs.err"; then
            sub_path="$WORK/$sub_basename"
            printf '  %ssubtitles: %s%s\n' "$DIM" "$sub_basename" "$RST"
            [ "${SAIL_DEBUG:-0}" = 1 ] && printf '  %s(saved to %s, %s bytes)%s\n' \
                "$DIM" "$sub_path" "$(wc -c < "$sub_path" | tr -d ' ')" "$RST" >&2
        elif [ "${SAIL_DEBUG:-0}" = 1 ]; then
            printf '  %ssubtitles: failed to fetch %s%s\n' "$DIM" "$sub_torrent_path" "$RST" >&2
            [ -s "$WORK/subs.err" ] && sed 's/^/    /' "$WORK/subs.err" >&2
        fi
    fi

    printf '  streaming — quit the player to stop\n\n'
    render_status "STREAMING" "file: $(basename "$vid_path")" "$title" &
    RENDER_PID=$!
    {
        case "$PLAYER" in
            iina) if [ -n "$sub_path" ]; then
                      # verified against IINA's own mpv IPC socket (track-list /
                      # sid), not just guessed: --mpv-sub-file (CLI-only alias)
                      # and --mpv-sub-files-append both get silently dropped by
                      # IINA's option relay — the append variant never even
                      # appears in track-list. The plain "set" form, --mpv-sub-
                      # files (no -append), is what actually gets applied and
                      # auto-selected (confirmed selected:true, sid:1)
                      "$IINA_CLI" --keep-running --mpv-sub-files="$sub_path" "$stream_url"
                  else
                      "$IINA_CLI" --keep-running "$stream_url"
                  fi ;;
            mpv)  if [ -n "$sub_path" ]; then
                      mpv --sub-file="$sub_path" "$stream_url"
                  else
                      mpv "$stream_url"
                  fi ;;
            vlc)  if [ -n "$sub_path" ]; then
                      vlc --sub-file="$sub_path" "$stream_url"
                  else
                      vlc "$stream_url"
                  fi ;;
        esac
    } || rc=$?
    # player closed — bin/sail's EXIT trap kills the webtorrent server and
    # wipes $WORK (including the streamed video)
    return "$rc"
}

# ---- downloading ----------------------------------------------------------

# sail_download <magnet> <meta-path> <title> <dir>
sail_download() {
    local magnet="$1" meta="$2" title="$3" dir="$4"
    local wt_status=0 elapsed

    FALLBACK_DOWNLOAD() {
        printf '  %s%s%s\n\n' "$YLW" "$1" "$RST"
        # foreground, not exec: exec would replace the shell and skip the
        # EXIT trap (temp dir cleanup, renderer/server teardown)
        local rc=0
        webtorrent "$magnet" --out "$dir" -i || rc=$?
        return "$rc"
    }

    if ! sail_can_serve; then
        FALLBACK_DOWNLOAD "couldn't read the file list — downloading the whole torrent"
        return $?
    fi

    sail_pick_download_files || return 0

    printf '  downloading %s%d file%s%s to %s%s%s\n\n' \
        "$BLD" "$N_SEL" "$([ "$N_SEL" = 1 ] || printf s)" "$RST" "$CYN" "$dir" "$RST"
    SECONDS=0
    node "$LIB_DIR/wt.js" "$WTMOD" get "$meta" "$dir" \
        "$SEL_IDXS" "$OPTS_JSON" >"$WORK/wt.log" 2>&1 &
    WT_PID=$!
    render_status "DOWNLOADING" "$N_SEL file$([ "$N_SEL" = 1 ] || printf s) to $dir" "$title" &
    # shellcheck disable=SC2034  # read by bin/sail's EXIT trap
    RENDER_PID=$!
    wait "$WT_PID" || wt_status=$?
    WT_PID=""
    stop_render
    if [ "$SECONDS" -lt 3600 ]; then
        elapsed="$((SECONDS / 60))m$(printf '%02d' $((SECONDS % 60)))s"
    else
        elapsed="$((SECONDS / 3600))h$(printf '%02d' $((SECONDS % 3600 / 60)))m"
    fi
    if [ "$wt_status" -eq 0 ]; then
        printf '  %sdone%s in %s — saved to %s%s%s\n' \
            "$GRN" "$RST" "$elapsed" "$CYN" "$dir" "$RST"
        notify "sail" "Download complete: $title"
    else
        printf '  %sdownload didn'"'"'t finish cleanly (%s)%s\n' "$RED" "$wt_status" "$RST"
        # wt.log holds the real webtorrent error — show it, don't just exit
        if [ -s "$WORK/wt.log" ]; then
            tail -3 "$WORK/wt.log" | while IFS= read -r wl; do
                printf '  %s%s%s\n' "$DIM" "$(cutw "$wl" 118)" "$RST"
            done
        fi
        notify "sail" "Download failed: $title"
    fi
    return "$wt_status"
}
