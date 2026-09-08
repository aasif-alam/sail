# sail bash completion.
#
# Source this file, or copy it where your bash-completion setup auto-loads
# scripts from (e.g. "$(brew --prefix)/etc/bash_completion.d/").

_sail() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "sources -s -d -h -v --version" -- "$cur"))
    fi
}
complete -F _sail sail
