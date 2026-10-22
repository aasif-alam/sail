#!/usr/bin/env bash
# sources-ui.sh — the `sail sources` tick-list.
#
# Sourced by bin/sail. Which sources count as enabled comes from
# `search.py --enabled`, the same parser searches use — so a trailing
# space, a comment, or a missing file can never make the UI disagree with
# what a search actually does. Saving is atomic: a temp file is renamed
# over the config, so an interrupt can't leave a truncated (authoritative)
# source list behind.

# sail_sources_ui <config-path>
sail_sources_ui() {
    local CONF="$1"
    local -a NAMES=() DESCS=() ON=()
    local DIRTY=0 SNOTE="" name desc _def enabled_names TMPF
    local NAMEW DESCW ROWW BAD n

    mkdir -p "$(dirname "$CONF")"

    python3 "$LIB_DIR/search.py" --list-sources > "$WORK/source-list" || return 1
    if [ ! -s "$WORK/source-list" ]; then
        printf '  could not list sources (is search.py intact?)\n' >&2
        return 1
    fi
    python3 "$LIB_DIR/search.py" --enabled > "$WORK/source-on" || return 1
    enabled_names=" $(tr '\n' ' ' < "$WORK/source-on") "

    while IFS=$'\t' read -r name desc _def; do
        NAMES+=("$name"); DESCS+=("$desc")
        case "$enabled_names" in
            *" $name "*) ON+=(1) ;;
            *) ON+=(0) ;;
        esac
    done < "$WORK/source-list"

    # column widths come from the data, not a hardcoded %-32s — tcsv's
    # description is 37 chars and overflowed the old fixed column
    NAMEW="$(printf '%s\n' "${NAMES[@]}" | awk '{ if (length($0) > m) m = length($0) } END { printf "%d", m }')"
    DESCW="$(printf '%s\n' "${DESCS[@]}" | awk '{ if (length($0) > m) m = length($0) } END { printf "%d", m }')"
    ROWW=$((NAMEW + 1 + DESCW))

    # one content row: "  │ <colored text> <pad> │". Width is measured by
    # wc -m (chars, locale-aware) on the escape-stripped text — awk's
    # length() is byte-based on stock macOS and would misplace the right
    # edge whenever the content holds a multibyte char like the title's —
    boxline() {
        local ln vis pad
        while IFS= read -r ln; do
            vis="$(printf '%s' "$ln" | sed $'s/\x1b\\[[0-9;]*m//g' \
                | LC_ALL="$UTF8_LOCALE" wc -m | tr -d ' ')"
            pad=$((ROWW + 12 - vis))
            [ "$pad" -ge 0 ] || pad=0
            printf '  │ %s%*s│\n' "$ln" "$pad" ""
        done <<< "$1"
    }

    draw() {
        local i en=0
        for i in "${!NAMES[@]}"; do
            [ "${ON[$i]}" = 1 ] && en=$((en + 1))
        done
        printf '\033[H\033[2J'
        printf '  ╭─'
        for ((i = 0; i < ROWW + 12; i++)); do printf '─'; done
        printf '╮\n'
        boxline "$(printf '%ssources%s — used by every search %s%d/%d enabled%s' \
            "$BLD" "$RST" "$DIM" "$en" "${#NAMES[@]}" "$RST")"
        boxline ""
        for i in "${!NAMES[@]}"; do
            if [ "${ON[$i]}" = 1 ]; then
                boxline "$(printf '%s%-2s%s %s[x]%s %-*s %s%s%s' \
                    "$DIM" "$((i + 1))" "$RST" "$GRN" "$RST" \
                    "$NAMEW" "${NAMES[$i]}" "" "${DESCS[$i]}" "$RST")"
            else
                boxline "$(printf '%s%-2s%s %s[ ]%s %-*s %s%s%s' \
                    "$DIM" "$((i + 1))" "$RST" "$DIM" "$RST" \
                    "$NAMEW" "${NAMES[$i]}" "$DIM" "${DESCS[$i]}" "$RST")"
            fi
        done
        boxline ""
        boxline "$(printf 'toggle: number (e.g. %s1 3%s)   %sa%s all   %sx%s none' \
            "$BLD" "$RST" "$BLD" "$RST" "$BLD" "$RST")"
        boxline "$(printf '%ss%s save   %sq%s quit' "$BLD" "$RST" "$BLD" "$RST")$SNOTE"
        printf '  ╰─'
        for ((i = 0; i < ROWW + 12; i++)); do printf '─'; done
        printf '╯\n\n  > '
    }

    toggle() {
        local n="$1" i
        case "$n" in
            ''|*[!0-9]*) return 1 ;;
        esac
        i=$((n - 1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "${#NAMES[@]}" ]; then
            if [ "${ON[$i]}" = 1 ]; then ON[i]=0; else ON[i]=1; fi
            DIRTY=1
            return 0
        fi
        return 1
    }

    while draw && read -r -a tokens; do
        case "${tokens[0]:-}" in
            s|S)
                if [ "$DIRTY" = 1 ]; then
                    TMPF="$CONF.tmp.$$"
                    {
                        for i in "${!NAMES[@]}"; do
                            if [ "${ON[$i]}" = 1 ]; then
                                printf '%s\n' "${NAMES[$i]}"
                            fi
                        done
                    } > "$TMPF"
                    mv "$TMPF" "$CONF"
                    printf '\n  saved %s%s%s\n' "$BLD" "$CONF" "$RST"
                else
                    printf '\n  nothing changed\n'
                fi
                return 0
                ;;
            q|Q) printf '\n  (not saved)\n'; return 0 ;;
            a|A) for i in "${!NAMES[@]}"; do ON[i]=1; done; DIRTY=1; SNOTE="" ;;
            x|X) for i in "${!NAMES[@]}"; do ON[i]=0; done; DIRTY=1; SNOTE="" ;;
            *)
                BAD=""
                for n in "${tokens[@]+"${tokens[@]}"}"; do
                    if ! toggle "$n"; then
                        [ -n "$BAD" ] && BAD="$BAD "
                        BAD="$BAD$n"
                    fi
                done
                # silent no-op on bad input read as ignored keypresses —
                # echo them back dim, like the pickers' NOTICE
                if [ -n "$BAD" ]; then
                    SNOTE=$'\n'"unknown: $BAD"
                else
                    SNOTE=""
                fi ;;
        esac
    done
    return 0
}
