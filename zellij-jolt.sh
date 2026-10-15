#!/usr/bin/env bash
# zellij-jolt — Jolt into your Zellij sessions
#
# A keyboard-first fzf picker for Zellij sessions: switch, create, rename,
# pin and clean up sessions, open project directories and layouts. Safe to
# use as a terminal's startup command — on fatal errors it falls back to a
# login shell instead of closing the window.
#
# fzf callbacks re-invoke this script by absolute path ($JOLT_SELF) so they
# do not depend on the user's $SHELL. Sourcing with JOLT_NO_MAIN=1 defines
# the functions only (used by the bats test suite).
set -uo pipefail

# ── core ────────────────────────────────────────────────────────────────

JOLT_VERSION="2.0.0"

# Feature floors.
JOLT_MIN_BASH="4.2"
JOLT_MIN_FZF="0.38.0"
JOLT_MIN_ZELLIJ="0.39.0"

# _jolt_resolve_self — absolute path of this script without `readlink -f`
# (not on stock macOS). Follows one symlink level, e.g. ~/.local/bin link.
_jolt_resolve_self() {
    local src="${BASH_SOURCE[0]:-$0}" link dir
    if [[ -L $src ]]; then
        link=$(readlink "$src") || link=""
        if [[ -n $link ]]; then
            if [[ $link == /* ]]; then
                src=$link
            else
                src="$(dirname "$src")/$link"
            fi
        fi
    fi
    dir=$(cd "$(dirname "$src")" && pwd -P) || return 1
    printf '%s/%s\n' "$dir" "$(basename "$src")"
}

# _jolt_find_cache_dir — highest-numbered zellij contract_version_* cache.
_jolt_find_cache_dir() {
    local base="${XDG_CACHE_HOME:-$HOME/.cache}/zellij" d n best=-1 best_dir=""
    for d in "$base"/contract_version_*/session_info; do
        [[ -d $d ]] || continue
        n=${d%/session_info}
        n=${n##*contract_version_}
        [[ $n =~ ^[0-9]+$ ]] || continue
        if ((10#$n > best)); then
            best=$((10#$n))
            best_dir=$d
        fi
    done
    printf '%s\n' "${best_dir:-$base/contract_version_1/session_info}"
}

JOLT_SELF=$(_jolt_resolve_self) || JOLT_SELF="${BASH_SOURCE[0]:-$0}"
: "${JOLT_CACHE_DIR:=$(_jolt_find_cache_dir)}"
: "${JOLT_ZELLIJ_CONFIG:=${ZELLIJ_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zellij/config.kdl}}"
: "${JOLT_CONFIG_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/zellij-jolt/config}"
: "${JOLT_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/zellij-jolt}"
JOLT_DRY_RUN="${JOLT_DRY_RUN:-}"
FZF_VER="${FZF_VER:-}"

warn() {
    printf 'zellij-jolt: %s\n' "$*" >&2
}

# fallback_shell — keep the terminal usable when we are its startup command:
# replace ourselves with a login shell if stdin is a tty, otherwise exit 1.
# JOLT_NO_FALLBACK=1 (tests, scripts) always exits instead.
fallback_shell() {
    local sh="${SHELL:-/bin/sh}"
    if [[ -z ${JOLT_NO_FALLBACK:-} && -t 0 ]]; then
        # Never re-exec ourselves if we *are* the configured shell.
        case "${sh##*/}" in
            zellij-jolt | zellij-jolt.sh) sh=/bin/sh ;;
        esac
        exec "$sh" -l
    fi
    exit 1
}

die() {
    warn "$*"
    fallback_shell
}

# ver_to_int "0.74.5" → 74005 (major*1000000 + minor*1000 + patch).
# Leading text such as "zellij " and suffixes such as "-rc1" are ignored.
ver_to_int() {
    local v="$1"
    if [[ $v =~ ([0-9]+)(\.([0-9]+))?(\.([0-9]+))? ]]; then
        echo $((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[3]:-0} * 1000 + 10#${BASH_REMATCH[5]:-0}))
    else
        echo 0
    fi
}

# fzf_detect — set FZF_VER (ver_to_int scale) from `fzf --version`, 0 if absent.
fzf_detect() {
    local out
    out=$(fzf --version 2>/dev/null) || out=""
    FZF_VER=$(ver_to_int "${out%% *}")
}

# fzf_has FEATURE — succeeds when the detected fzf supports FEATURE.
fzf_has() {
    local need
    case "$1" in
        with-shell) need=0.51.0 ;;
        ghost) need=0.61.0 ;;
        footer) need=0.63.0 ;;
        header-border) need=0.72.0 ;;
        *) return 1 ;;
    esac
    [[ -n $FZF_VER ]] || fzf_detect
    ((FZF_VER >= $(ver_to_int "$need")))
}

# check_deps — verify bash, fzf and zellij meet the floors. Prints every
# problem found and returns non-zero if any.
check_deps() {
    local rc=0 out have
    have="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if (($(ver_to_int "$have") < $(ver_to_int "$JOLT_MIN_BASH"))); then
        warn "bash >= $JOLT_MIN_BASH required (found $have; macOS: brew install bash)"
        rc=1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
        warn "fzf not found (need >= $JOLT_MIN_FZF)"
        rc=1
    else
        fzf_detect
        if ((FZF_VER < $(ver_to_int "$JOLT_MIN_FZF"))); then
            warn "fzf >= $JOLT_MIN_FZF required"
            rc=1
        fi
    fi
    if ! command -v zellij >/dev/null 2>&1; then
        warn "zellij not found (need >= $JOLT_MIN_ZELLIJ)"
        rc=1
    else
        out=$(zellij --version 2>/dev/null) || out=""
        if (($(ver_to_int "$out") < $(ver_to_int "$JOLT_MIN_ZELLIJ"))); then
            warn "zellij >= $JOLT_MIN_ZELLIJ required (found ${out:-unknown})"
            rc=1
        fi
    fi
    return "$rc"
}

# ── config ──────────────────────────────────────────────────────────────

# Allowed config keys (without the CFG_ prefix). Anything else is warned
# about and ignored.
JOLT_CFG_KEYS=(
    PROJECT_ROOTS PROJECT_DEPTH DEFAULT_LAYOUT PREVIEW PREVIEW_POS
    SHOW_EXITED THEME CONFIRM_DELETE
    KEY_DELETE KEY_PURGE KEY_RENAME KEY_PIN KEY_PROJECT KEY_LAYOUT
    KEY_PREVIEW KEY_HELP KEY_CREATE
)

_cfg_defaults() {
    CFG_PROJECT_ROOTS="$HOME/projects $HOME/code $HOME/src $HOME/dev"
    CFG_PROJECT_DEPTH=3
    CFG_DEFAULT_LAYOUT=""
    CFG_PREVIEW=on
    CFG_PREVIEW_POS=right
    CFG_SHOW_EXITED=on
    CFG_THEME=auto
    CFG_CONFIRM_DELETE=on
    CFG_KEY_DELETE=ctrl-d
    CFG_KEY_PURGE=alt-d
    CFG_KEY_RENAME=ctrl-r
    CFG_KEY_PIN=ctrl-t
    CFG_KEY_PROJECT=ctrl-o
    CFG_KEY_LAYOUT=ctrl-l
    CFG_KEY_PREVIEW=ctrl-/
    CFG_KEY_HELP='?'
    CFG_KEY_CREATE=alt-enter
}

# _cfg_expand_tilde VALUE — leading "~" or "~/" → $HOME.
_cfg_expand_tilde() {
    local v="$1"
    if [[ $v == "~" ]]; then
        v=$HOME
    elif [[ $v == "~/"* ]]; then
        v="$HOME/${v#\~/}"
    fi
    printf '%s' "$v"
}

# config_load — read $JOLT_CONFIG_FILE as KEY=VALUE lines into CFG_* vars.
# Values are literal: never sourced or eval'd; only quotes and ~ handled.
config_load() {
    _cfg_defaults
    local file="$JOLT_CONFIG_FILE" line key val n=0 k ok word out
    local -a words
    [[ -f $file && -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        # trim surrounding whitespace
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line || $line == \#* ]] && continue
        if [[ ! $line =~ ^([A-Z_]+)=(.*)$ ]]; then
            warn "config line $n: ignored (expected KEY=VALUE)"
            continue
        fi
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        ok=""
        for k in "${JOLT_CFG_KEYS[@]}"; do
            [[ $k == "$key" ]] && ok=1 && break
        done
        if [[ -z $ok ]]; then
            warn "config line $n: unknown key $key"
            continue
        fi
        # strip one pair of matching surrounding quotes
        if [[ ${#val} -ge 2 && (($val == \"*\" ) || ($val == \'*\')) ]]; then
            val=${val:1:${#val}-2}
        fi
        if [[ $key == PROJECT_ROOTS ]]; then
            out=""
            read -r -a words <<<"$val"
            for word in "${words[@]}"; do
                out+="${out:+ }$(_cfg_expand_tilde "$word")"
            done
            val=$out
        else
            val=$(_cfg_expand_tilde "$val")
        fi
        printf -v "CFG_$key" '%s' "$val"
    done <"$file"
    return 0
}

# ── theme ───────────────────────────────────────────────────────────────

# (Task: theme_load — zellij theme resolution and fzf color mapping.)

# ── data ────────────────────────────────────────────────────────────────

# (Task: sessions_read, meta_read, layout_cwd, state_*, last_used.)

# ── render ──────────────────────────────────────────────────────────────

# _char_width CODEPOINT — display width of one code point in REPLY
# (0 combining, 2 East Asian wide / emoji, 1 otherwise).
_char_width() {
    local c=$1
    if ((c >= 0x0300 && c <= 0x036F)); then
        REPLY=0
    elif ((c >= 0x1100 && c <= 0x115F)) ||
        ((c >= 0x2E80 && c <= 0xA4CF)) ||
        ((c >= 0xAC00 && c <= 0xD7A3)) ||
        ((c >= 0xF900 && c <= 0xFAFF)) ||
        ((c >= 0xFE30 && c <= 0xFE4F)) ||
        ((c >= 0xFF00 && c <= 0xFF60)) ||
        ((c >= 0xFFE0 && c <= 0xFFE6)) ||
        ((c >= 0x1F300 && c <= 0x1F64F)) ||
        ((c >= 0x1F680 && c <= 0x1F6FF)) ||
        ((c >= 0x1F900 && c <= 0x1F9FF)) ||
        ((c >= 0x20000 && c <= 0x3FFFD)); then
        REPLY=2
    else
        REPLY=1
    fi
}

# dwidth STR — terminal display width of STR.
dwidth() {
    local s="$1" i c w=0
    if [[ $s != *[![:ascii:]]* ]]; then
        echo "${#s}"
        return
    fi
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        _char_width "$c"
        w=$((w + REPLY))
    done
    echo "$w"
}

# trunc STR W — STR cut to display width <= W, ending in "…" when cut.
trunc() {
    local s="$1" max="$2" i c ch w=0 out=""
    if (($(dwidth "$s") <= max)); then
        printf '%s\n' "$s"
        return
    fi
    if ((max <= 0)); then
        echo ""
        return
    fi
    for ((i = 0; i < ${#s}; i++)); do
        ch=${s:i:1}
        printf -v c '%d' "'$ch"
        _char_width "$c"
        ((w + REPLY > max - 1)) && break
        w=$((w + REPLY))
        out+=$ch
    done
    printf '%s…\n' "$out"
}

# pad STR W — trunc STR to W and right-pad with spaces to exactly W columns.
pad() {
    local s w
    s=$(trunc "$1" "$2")
    w=$(dwidth "$s")
    printf '%s%*s\n' "$s" $(($2 > w ? $2 - w : 0)) ""
}

# ── actions ─────────────────────────────────────────────────────────────

# _bytelen STR — byte length (not character length) of STR.
_bytelen() {
    local LC_ALL=C
    echo "${#1}"
}

# sanitize_name STR — session-safe name: control chars dropped, "/" → "-",
# whitespace runs → "-", trimmed, capped at 48 bytes (zellij socket path
# limit) on a character boundary. Returns 1 when nothing is left.
sanitize_name() {
    local s="$1" out="" p
    local -a parts
    # tabs/newlines become separators; other control chars vanish
    s=${s//[$'\t\n\r']/ }
    s=${s//[[:cntrl:]]/}
    s=${s//\//-}
    read -r -a parts <<<"$s"
    for p in "${parts[@]}"; do
        out+="${out:+-}$p"
    done
    while (($(_bytelen "$out") > 48)); do
        out=${out%?}
    done
    [[ -n $out ]] || return 1
    printf '%s\n' "$out"
}

# (Task: go, act_delete, act_purge, act_rename, act_pin, pick_project,
#  pick_layout.)

# ── picker ──────────────────────────────────────────────────────────────

# (Task: picker_main.)

# ── main ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
zellij-jolt $JOLT_VERSION — jolt into your Zellij sessions

Usage:
  zellij-jolt                         picker (default)
  zellij-jolt --list                  print picker rows (used by fzf reload)
  zellij-jolt --preview KEY           render preview for a row key
  zellij-jolt --action ACT KEY        keybind handler: delete|rename|pin|purge
  zellij-jolt --dry-run               print final zellij command instead of exec
  zellij-jolt --init-shell SHELL      print guarded auto-start snippet (bash|zsh|fish)
  zellij-jolt --doctor                environment diagnostics
  zellij-jolt --version | --help

Config: $JOLT_CONFIG_FILE
EOF
}

# init_shell SHELL — print a guarded auto-start snippet for SHELL.
init_shell() {
    case "$1" in
        zsh)
            cat <<'EOF'
# zellij-jolt auto-start (set JOLT_SKIP=1 to bypass)
[[ -z $ZELLIJ && -z $TMUX && -t 0 && -o interactive && $TERM != dumb && $TERM_PROGRAM != vscode && -z $JOLT_SKIP ]] && exec zellij-jolt
EOF
            ;;
        bash)
            cat <<'EOF'
# zellij-jolt auto-start (set JOLT_SKIP=1 to bypass)
[[ -z $ZELLIJ && -z $TMUX && -t 0 && $- == *i* && $TERM != dumb && $TERM_PROGRAM != vscode && -z $JOLT_SKIP ]] && exec zellij-jolt
EOF
            ;;
        fish)
            cat <<'EOF'
# zellij-jolt auto-start (set JOLT_SKIP=1 to bypass)
if status is-interactive; and not set -q ZELLIJ; and not set -q TMUX; and test -t 0; and test "$TERM" != dumb; and test "$TERM_PROGRAM" != vscode; and not set -q JOLT_SKIP
    exec zellij-jolt
end
EOF
            ;;
        *)
            return 2
            ;;
    esac
}

# _usage_error MSG — message + usage on stderr, exit 2.
_usage_error() {
    warn "$1"
    usage >&2
    exit 2
}

main() {
    case "${1:-}" in
        "")
            check_deps || die "missing or outdated dependencies"
            die "not implemented"
            ;;
        --version | -V)
            echo "zellij-jolt $JOLT_VERSION"
            ;;
        --help | -h)
            usage
            ;;
        --list)
            die "not implemented"
            ;;
        --preview)
            (($# >= 2)) || _usage_error "--preview needs a KEY"
            die "not implemented"
            ;;
        --action)
            (($# >= 3)) || _usage_error "--action needs ACT and KEY"
            die "not implemented"
            ;;
        --dry-run)
            JOLT_DRY_RUN=1
            check_deps || die "missing or outdated dependencies"
            die "not implemented"
            ;;
        --init-shell)
            (($# >= 2)) || _usage_error "--init-shell needs a SHELL (bash|zsh|fish)"
            init_shell "$2" || _usage_error "unsupported shell: $2 (bash|zsh|fish)"
            ;;
        --doctor)
            die "not implemented"
            ;;
        *)
            _usage_error "unknown option: $1"
            ;;
    esac
}

[[ ${JOLT_NO_MAIN:-} == 1 ]] || main "$@"
