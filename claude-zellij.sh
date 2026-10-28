#!/usr/bin/env bash
# claude-zellij — run Claude Code so a Zellij pane reopens the same
# conversation after Zellij resurrects the session (reboot, `zellij attach`
# of an exited session, zellij-jolt's resurrect).
#
# How: the pane gets an ID baked into this script's own command line.
# Zellij saves that command line and runs it again on restore. The ID maps
# to a file holding the pane's Claude conversation ID, which is resumed.
#
# Claude runs as a normal foreground child talking to the terminal directly;
# this script never reads your input or Claude's output. It adds no flags of
# its own: whatever you pass (e.g. a model or permission mode) is passed on.
#
# Bundled with zellij-jolt. Env: CLAUDE_ZELLIJ_BIN (claude to run),
# CLAUDE_ZELLIJ_STATE (state dir), CLAUDE_ZELLIJ_KEEP_DAYS (default 60).

set -uo pipefail

STATE_DIR="${CLAUDE_ZELLIJ_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-zellij}"
UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

die() {
    printf 'claude-zellij: %s\n' "$*" >&2
    exit 1
}

# Zellij may restore panes with a bare system PATH (a terminal that starts
# zellij directly skips your rc files): put the user's bin dirs first.
for d in "$HOME/bin" "$HOME/.local/bin" ${XDG_BIN_HOME:+"$XDG_BIN_HOME"}; do
    [[ -d $d ]] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# find_claude — the real claude binary in CLAUDE_BIN. Only executable files
# count (a broken npm install can leave a non-executable /usr/bin/claude
# stub that fails with "permission denied"), and never this wrapper.
find_claude() {
    local c d ifs=$IFS self
    local -a dirs
    self=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
    for c in "${CLAUDE_ZELLIJ_BIN:-}" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
        [[ -n $c && -f $c && -x $c && ! $c -ef $self ]] && { CLAUDE_BIN=$c; return 0; }
    done
    IFS=: read -r -a dirs <<<"$PATH"
    IFS=$ifs
    for d in "${dirs[@]}"; do
        c="${d:-.}/claude"
        [[ -f $c && -x $c && ! $c -ef $self ]] && { CLAUDE_BIN=$c; return 0; }
    done
    return 1
}

new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-F' 'a-f'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' |
            sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

# conversation_exists ID — Claude keeps each conversation as
# ~/.claude/projects/<project>/<ID>.jsonl.
conversation_exists() {
    compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/$1.jsonl" >/dev/null
}

find_claude || die "cannot find an executable 'claude' (set CLAUDE_ZELLIJ_BIN)"

# Outside zellij there is nothing to restore: plain claude.
[[ -n ${ZELLIJ:-} || ${1:-} == --pane-id ]] || exec "$CLAUDE_BIN" "$@"

# Non-interactive uses go straight to claude.
first_word=""
for arg in "$@"; do
    [[ $arg != -* ]] && { first_word=$arg; break; }
done
case "$first_word" in
    agents | attach | auth | auto-mode | config | doctor | gateway | import | install | logs | mcp | migrate-installer | plugin | plugins | project | respawn | rm | setup-token | stop | ultrareview | update | upgrade)
        exec "$CLAUDE_BIN" "$@"
        ;;
esac
for arg in "$@"; do
    case "$arg" in
        -p | --print | -h | --help | -v | --version) exec "$CLAUDE_BIN" "$@" ;;
    esac
done

# First run in a pane: pick an ID and restart with it on the command line,
# so it becomes part of what Zellij saves for this pane. The absolute path
# keeps the restore independent of PATH.
if [[ ${1:-} != --pane-id ]]; then
    self=$(cd -P -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")
    exec "$self" --pane-id "$(new_uuid)" "$@"
fi
pane_id=${2:-}
shift 2 2>/dev/null || shift $#
[[ $pane_id =~ $UUID_RE ]] || die "bad --pane-id: $pane_id"

# Pull the conversation-picking flags out of the original command line:
# on restore, the pane's recorded conversation wins over them.
rest=() want_id="" pick=()
while (($#)); do
    case "$1" in
        -r | --resume)
            if [[ ${2:-} =~ $UUID_RE ]]; then
                want_id=$2
                shift
            else
                pick=("$1")
            fi
            ;;
        --resume=*)
            if [[ ${1#*=} =~ $UUID_RE ]]; then want_id=${1#*=}; else pick=("$1"); fi
            ;;
        --session-id)
            [[ ${2:-} =~ $UUID_RE ]] && want_id=$2
            shift
            ;;
        --session-id=*)
            [[ ${1#*=} =~ $UUID_RE ]] && want_id=${1#*=}
            ;;
        -c | --continue) pick=("$1") ;;
        *) rest+=("$1") ;;
    esac
    shift
done

mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
state_file="$STATE_DIR/$pane_id"
find "$STATE_DIR" -type f -mtime +"${CLAUDE_ZELLIJ_KEEP_DAYS:-60}" -delete 2>/dev/null

session_id=$(cat "$state_file" 2>/dev/null)
[[ $session_id =~ $UUID_RE ]] || session_id=""
if [[ -n $session_id ]] && conversation_exists "$session_id"; then
    session_args=(--resume "$session_id")
elif [[ -n $want_id ]] && conversation_exists "$want_id"; then
    session_id=$want_id
    session_args=(--resume "$session_id")
elif ((${#pick[@]})); then
    # --continue / the --resume picker: the watcher below records whichever
    # conversation Claude opens.
    session_id=""
    session_args=("${pick[@]}")
else
    session_id=${want_id:-$(new_uuid)}
    session_args=(--session-id "$session_id")
fi
[[ -z $session_id ]] || printf '%s\n' "$session_id" >"$state_file"

# Follow conversation switches (/resume, /clear, the picker): Claude records
# its active conversation in ~/.claude/sessions/<pid>.json.
watcher=""
if command -v pgrep >/dev/null 2>&1; then
    (
        wrapper_pid=$$
        sessions="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
        while kill -0 "$wrapper_pid" 2>/dev/null; do
            sleep 2
            for pid in $(pgrep -P "$wrapper_pid"); do
                current=$(sed -n 's/.*"sessionId": *"\([^"]*\)".*/\1/p' "$sessions/$pid.json" 2>/dev/null)
                [[ $current =~ $UUID_RE ]] || continue
                [[ $current == "$(cat "$state_file" 2>/dev/null)" ]] || printf '%s\n' "$current" >"$state_file"
            done
        done
    ) </dev/null >/dev/null 2>&1 &
    watcher=$!
fi
trap '[[ -n $watcher ]] && kill "$watcher" 2>/dev/null' EXIT

"$CLAUDE_BIN" "${session_args[@]}" ${rest[@]+"${rest[@]}"}
