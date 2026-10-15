#!/usr/bin/env bash
# End-to-end smoke test: drives the real picker (real fzf) inside a PRIVATE
# tmux server (-L jolt-smoke) with the zellij stub on PATH, fixture cache
# and SHELL=zsh. Never touches the user's own tmux or zellij: only the
# jolt-smoke server is created and killed, and the stub replaces zellij.
#
# Usage: test/smoke.sh        (exit 0 when every check passes)
# SMOKE_SCREEN=FILE saves the first picker screen capture to FILE.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK=jolt-smoke
TMP=$(mktemp -d "${TMPDIR:-/tmp}/jolt-smoke.XXXXXX")
FAIL=0

tm() { tmux -L "$SOCK" -f /dev/null "$@"; }

cleanup() {
    tm kill-server 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

for t in tmux fzf; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "SKIP: $t not installed"
        exit 0
    }
done
ZSH=$(command -v zsh || echo /usr/bin/zsh)

mkdir -p "$TMP/cache" "$TMP/config" "$TMP/state"
cp -r "$REPO/test/fixtures/session_info/." "$TMP/cache/"
chmod -R u+w "$TMP/cache"
: >"$TMP/stub.log"

# The command each run starts in the pane: a clean environment (no
# ZELLIJ/TMUX from the caller) with the stub first on PATH.
run_cmd() {
    printf '%q ' env -i \
        "HOME=$HOME" "TERM=tmux-256color" "LANG=${LANG:-C.UTF-8}" \
        "PATH=$REPO/test/stubs:$PATH" "SHELL=$ZSH" \
        "XDG_CONFIG_HOME=$TMP/config" "XDG_STATE_HOME=$TMP/state" \
        "JOLT_CACHE_DIR=$TMP/cache" "JOLT_ZELLIJ_CONFIG=$TMP/zellij.kdl" \
        "STUB_LS=$REPO/test/fixtures/ls/mixed.txt" "STUB_LOG=$TMP/stub.log" \
        "JOLT_NO_FALLBACK=1" "$@" \
        "$REPO/zellij-jolt.sh" --dry-run
    printf '; echo RC=$?; sleep 30'
}

# start ENV... — fresh pane running the picker.
start() {
    tm kill-server 2>/dev/null
    tm new-session -d -x 120 -y 30 "$(run_cmd "$@")"
}

screen() { tm capture-pane -p; }

# wait_for TEXT [SECONDS] — poll the pane until TEXT shows up.
wait_for() {
    local i n=$((${2:-5} * 10))
    for ((i = 0; i < n; i++)); do
        screen | grep -qF -- "$1" && return 0
        sleep 0.1
    done
    return 1
}

check() {
    local name=$1
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        echo "----- screen -----"
        screen
        echo "------------------"
        FAIL=1
    fi
}

has() { screen | grep -qF -- "$1"; }
hasnt() { ! screen | grep -qF -- "$1"; }

# 1. picker renders rows and the preview box under SHELL=zsh
start
wait_for "╭" 5
sleep 0.5
check "picker lists sessions" has "appr"
check "preview box rendered" has "╭"
check "no zsh errors" hasnt "bad pattern"
check "no command-not-found" hasnt "not found"
# cursor onto the first session row (after the 3 action rows)
tm send-keys Down Down Down
check "preview shows session details" wait_for "last used" 3
check "preview shows cached tabs" wait_for "1. " 3
[[ -n ${SMOKE_SCREEN:-} ]] && screen >"$SMOKE_SCREEN"

# 2. Esc quits with rc 0
tm send-keys Escape
check "esc exits 0" wait_for "RC=0" 3

# 3. typing a new name + Enter creates it
start
wait_for "╭" 5
tm send-keys -l zzznew
sleep 0.3
tm send-keys Enter
check "enter on typed name creates" wait_for "attach -c zzznew" 3
check "create exits 0" wait_for "RC=0" 3

# 4. ctrl-d on a session deletes it and reloads the list
start JOLT_ASSUME_YES=1
wait_for "╭" 5
tm send-keys -l memora_new
sleep 0.3
tm send-keys C-d
for _ in $(seq 30); do
    grep -q delete-session "$TMP/stub.log" && break
    sleep 0.1
done
check "ctrl-d deletes via zellij" grep -q $'delete-session\x1f-f\x1f--\x1fmemora_new' "$TMP/stub.log"
sleep 0.3
check "picker still open after delete" hasnt "RC="
tm send-keys Escape
check "esc after delete exits 0" wait_for "RC=0" 3

# 5. ? shows the key help in the preview
start
wait_for "╭" 5
tm send-keys '?'
check "help preview" wait_for "toggle preview" 3
tm send-keys Escape

if ((FAIL)); then
    echo "smoke: FAILED"
    exit 1
fi
echo "smoke: all checks passed"
