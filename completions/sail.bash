# sail bash completion.
#
# Source this file, or copy it where your bash-completion setup auto-loads
# scripts from (e.g. "$(brew --prefix)/etc/bash_completion.d/").

_sail() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    # --magnet takes a link, not a sail option or a source name
    if [ "$prev" = "--magnet" ]; then
        COMPREPLY=()
        return 0
    fi
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "sources wlist -s --stream -d --download -l --list --json --magnet -h --help -v --version" -- "$cur"))
    fi
}
complete -F _sail sail
