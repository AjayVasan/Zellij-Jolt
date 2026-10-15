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

# Bash floor guard. Must stay bash-3.2 safe: only POSIX tests, printf and
# exit/exec may run before it passes. JOLT_FAKE_BASH_MAJOR is a test hook
# (a faked major is paired with minor 0).
_jolt_bmaj=${JOLT_FAKE_BASH_MAJOR:-${BASH_VERSINFO[0]:-0}}
_jolt_bmin=${BASH_VERSINFO[1]:-0}
[ -n "${JOLT_FAKE_BASH_MAJOR:-}" ] && _jolt_bmin=0
if [ "$_jolt_bmaj" -lt 4 ] || { [ "$_jolt_bmaj" -eq 4 ] && [ "$_jolt_bmin" -lt 2 ]; }; then
    printf '%s\n' "zellij-jolt requires bash ≥4.2 (macOS: brew install bash)" >&2
    if [ -z "${JOLT_NO_FALLBACK:-}" ] && [ -t 0 ]; then
        case "${SHELL:-/bin/sh}" in
            *zellij-jolt*) exec /bin/sh -l ;;
            *) exec "${SHELL:-/bin/sh}" -l ;;
        esac
    fi
    # return when sourced, exit when executed
    return 1 2>/dev/null || exit 1
fi
unset _jolt_bmaj _jolt_bmin

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

# _jolt_is_utf8 LOCALE — succeeds for names like en_US.UTF-8 / C.utf8.
_jolt_is_utf8() {
    case "$1" in
        *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) return 0 ;;
    esac
    return 1
}

# _jolt_locale_init — width math needs a UTF-8 LC_CTYPE. If the effective
# locale is not UTF-8, switch to an installed UTF-8 one (C.UTF-8 preferred).
# Sets JOLT_UTF8=1 on success, 0 when none exists (render then degrades to
# ASCII so it never splits a multibyte sequence).
_jolt_locale_init() {
    local cur="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" l pick=""
    local -a avail
    JOLT_UTF8=1
    _jolt_is_utf8 "$cur" && return 0
    mapfile -t avail < <(locale -a 2>/dev/null)
    for l in "${avail[@]}"; do
        _jolt_is_utf8 "$l" || continue
        case "$l" in
            C.[Uu][Tt][Ff]*)
                pick=$l
                break
                ;;
            en_US.[Uu][Tt][Ff]*) pick=$l ;;
            *) [[ -n $pick ]] || pick=$l ;;
        esac
    done
    if [[ -z $pick ]]; then
        JOLT_UTF8=0
        return 0
    fi
    # LC_ALL overrides LC_CTYPE, so when it is set it must be replaced.
    if [[ -n ${LC_ALL:-} ]]; then
        export LC_ALL="$pick"
    else
        export LC_CTYPE="$pick"
    fi
}

_jolt_locale_init
JOLT_SELF=$(_jolt_resolve_self) || JOLT_SELF="${BASH_SOURCE[0]:-$0}"
: "${JOLT_CACHE_DIR:=$(_jolt_find_cache_dir)}"
: "${JOLT_ZELLIJ_CONFIG:=${ZELLIJ_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zellij/config.kdl}}"
: "${JOLT_CONFIG_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/zellij-jolt/config}"
: "${JOLT_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/zellij-jolt}"
JOLT_DRY_RUN="${JOLT_DRY_RUN:-}"
FZF_VER="${FZF_VER:-}"
# An inherited FZF_VER is trusted only if it is a plain integer.
[[ $FZF_VER =~ ^[0-9]+$ ]] || FZF_VER=""

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
        # execfail: a failed exec returns instead of killing the script.
        shopt -s execfail
        exec "$sh" -l
        exec /bin/sh -l
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

# theme_load runs on every fzf list/preview callback, so it is pure bash
# (no subshells or external tools) and never fails: anything it cannot
# parse is skipped and the worst case is the terminal's default colors.
# KDL handling is deliberately small: // and /* */ comments, /- slashdash,
# quoted strings, { } ; node separators and brace depth.

# _th_clean LINE — LINE with comments stripped and { } ; padded by spaces
# (outside strings), in REPLY. Carries /* */ state across lines in
# _th_inblock (dynamically scoped from theme_load).
_th_clean() {
    local s=$1 out="" c i n q=0
    if ((_th_inblock)); then
        if [[ $s != *'*/'* ]]; then
            REPLY=""
            return 0
        fi
        s=${s#*'*/'}
        _th_inblock=0
    fi
    # fast paths: whole-line // comment; no strings and no /* — cut at //
    # and pad separators
    c=${s#"${s%%[![:space:]]*}"}
    if [[ $c == //* || -z $c ]]; then
        REPLY=""
        return 0
    fi
    c=""
    if [[ $s != *\"* && $s != *'/*'* ]]; then
        s=${s%%//*}
        s=${s//\{/ \{ }
        s=${s//\}/ \} }
        REPLY=${s//;/ ; }
        return 0
    fi
    # strings but no /*: walk "-delimited segments (escapes parked in
    # \x02 \x03), padding only the unquoted ones — no per-char loop
    if [[ $s != *'/*'* ]]; then
        s=${s//'\\'/$'\x02'}
        s=${s//'\"'/$'\x03'}
        while :; do
            c=${s%%\"*}
            if ((!q)); then
                [[ $c == *//* ]] && i=1 && c=${c%%//*}
                c=${c//\{/ \{ }
                c=${c//\}/ \} }
                c=${c//;/ ; }
            fi
            out+=$c
            [[ ${i:-} == 1 || $s != *\"* ]] && break
            out+='"'
            s=${s#*\"}
            q=$((1 - q))
        done
        out=${out//$'\x02'/'\\'}
        REPLY=${out//$'\x03'/'\"'}
        return 0
    fi
    n=${#s}
    for ((i = 0; i < n; i++)); do
        c=${s:i:1}
        if ((q)); then
            out+=$c
            if [[ $c == '\' ]]; then
                out+=${s:i+1:1}
                i=$((i + 1))
            elif [[ $c == '"' ]]; then
                q=0
            fi
            continue
        fi
        case $c in
            '"') q=1; out+=$c ;;
            '/')
                case ${s:i+1:1} in
                    '/') break ;;
                    '*')
                        s=${s:i+2}
                        if [[ $s != *'*/'* ]]; then
                            _th_inblock=1
                            break
                        fi
                        s=${s#*'*/'}
                        n=${#s}
                        i=-1
                        out+=' '
                        ;;
                    *) out+=$c ;;
                esac
                ;;
            '{' | '}' | ';') out+=" $c " ;;
            *) out+=$c ;;
        esac
    done
    REPLY=$out
}

# _th_color TOKEN... — "R G B" | "#rrggbb" | "#rgb" → decimal "R G B" in
# REPLY. 256-color indices and anything else fail (caller skips them).
_th_color() {
    local a=${1:-} r g b
    if (($# >= 3)) && [[ $1 =~ ^[0-9]{1,3}$ && $2 =~ ^[0-9]{1,3}$ && $3 =~ ^[0-9]{1,3}$ ]]; then
        r=$((10#$1)) g=$((10#$2)) b=$((10#$3))
        ((r <= 255 && g <= 255 && b <= 255)) || return 1
        REPLY="$r $g $b"
        return 0
    fi
    (($# == 1)) || return 1
    a=${a#\"}
    a=${a%\"}
    if [[ $a =~ ^#[0-9a-fA-F]{6}$ ]]; then
        REPLY="$((16#${a:1:2})) $((16#${a:3:2})) $((16#${a:5:2}))"
    elif [[ $a =~ ^#[0-9a-fA-F]{3}$ ]]; then
        REPLY="$((16#${a:1:1}${a:1:1})) $((16#${a:2:1}${a:2:1})) $((16#${a:3:1}${a:3:1}))"
    else
        return 1
    fi
}

# _th_stmt — interpret one finished KDL node (_th_toks) at the current
# block path (_th_stack). Top level: theme / theme_dir. Inside
# themes { NAME { … } }: legacy palette keys (depth 2) or component
# blocks (depth 3), stored as _th_pal["NAME<US>ROLE"]="R G B".
_th_stmt() {
    local d=${#_th_stack[@]} key=${_th_toks[0]:-} name role=""
    ((${#_th_toks[@]})) || return 0
    [[ $key == /-* ]] && return 0
    if ((d == 0)); then
        if [[ ($key == theme || $key == theme_dir) && ${#_th_toks[@]} -ge 2 ]]; then
            _kdl_str "${_th_toks[*]:1}"
            if [[ $key == theme ]]; then
                _th_cfg_name=$REPLY
            else
                _th_cfg_dir=$REPLY
            fi
        fi
        return 0
    fi
    ((d == 2 || d == 3)) && [[ ${_th_stack[0]} == themes ]] || return 0
    name=${_th_stack[1]}
    if ((d == 2)); then
        case $key in
            fg | bg | red | green | yellow | blue | magenta | orange | cyan | black | white) role=$key ;;
            *) return 0 ;;
        esac
        _th_color "${_th_toks[@]:1}" || return 0
        _th_fmt[$name]=${_th_fmt[$name]:-legacy}
    else
        case ${_th_stack[2]}:$key in
            text_unselected:base) role=fg ;;
            text_unselected:background) role=bg ;;
            frame_selected:base) role=accent ;;
            ribbon_selected:background) role=accent2 ;;
            exit_code_error:base) role=red ;;
            exit_code_success:base) role=green ;;
            text_selected:emphasis_0) role=yellow ;;
            *) return 0 ;;
        esac
        _th_color "${_th_toks[@]:1}" || return 0
        _th_fmt[$name]=component
    fi
    _th_pal["$name"$'\x1f'"$role"]=$REPLY
}

# _th_scan FILE — feed FILE through the tokenizer, recording every theme
# it defines plus top-level theme / theme_dir. Expects `set -f` (tokens
# are word-split unquoted). Unreadable files are ignored.
_th_scan() {
    local file=$1 line tok skip=0
    local -a lines words _th_toks=() _th_stack=()
    [[ -f $file && -r $file ]] || return 0
    mapfile -t lines <"$file" 2>/dev/null || return 0
    _th_inblock=0
    for line in ${lines[@]+"${lines[@]}"}; do
        _th_clean "${line%$'\r'}"
        [[ $REPLY == *[![:space:]]* ]] || continue
        # shellcheck disable=SC2206  # word split; globbing is off (set -f)
        words=($REPLY)
        for tok in "${words[@]}"; do
            # skip>0: nesting depth inside an ignored block — a /- slashdash
            # block or any top-level block other than themes (keybinds…)
            if ((skip)); then
                case $tok in
                    '{') skip=$((skip + 1)) ;;
                    '}') skip=$((skip - 1)) ;;
                esac
                continue
            fi
            case $tok in
                '{')
                    _kdl_str "${_th_toks[*]-}"
                    if [[ ${_th_toks[0]:-} == /-* ]] ||
                        { ((${#_th_stack[@]} == 0)) && [[ $REPLY != themes ]]; }; then
                        skip=1
                    else
                        _th_stack+=("$REPLY")
                    fi
                    _th_toks=()
                    ;;
                '}')
                    _th_stmt
                    _th_toks=()
                    ((${#_th_stack[@]})) && unset "_th_stack[${#_th_stack[@]}-1]"
                    ;;
                ';')
                    _th_stmt
                    _th_toks=()
                    ;;
                *) _th_toks+=("$tok") ;;
            esac
        done
        ((skip)) || _th_stmt
        _th_toks=()
    done
    return 0
}

# _th_hex "R G B" — "#rrggbb" in REPLY.
_th_hex() {
    # shellcheck disable=SC2086  # deliberate split of "R G B"
    printf -v REPLY '#%02x%02x%02x' $1
}

# _th_mix "R G B" PCT — lighten toward white by PCT% (negative: darken
# toward black by -PCT%), "R G B" in REPLY.
_th_mix() {
    local p=$2 i
    # shellcheck disable=SC2206  # "R G B" digits only
    local -a c=($1)
    for i in 0 1 2; do
        if ((p >= 0)); then
            c[i]=$((c[i] + (255 - c[i]) * p / 100))
        else
            c[i]=$((c[i] * (100 + p) / 100))
        fi
    done
    REPLY="${c[0]} ${c[1]} ${c[2]}"
}

# _th_set_default [WHY] — terminal ANSI colors; fzf keeps its base 16
# scheme with ANSI-indexed accents (no hardcoded palette).
_th_set_default() {
    C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_ITA=$'\e[3m'
    C_ACCENT=$'\e[32m' C_OK=$'\e[32m' C_WARN=$'\e[33m'
    C_MUTED=$'\e[90m' C_TITLE=$'\e[1m'
    FZF_COLOR_OPT="16,hl:2,hl+:2,pointer:2,marker:2,spinner:3,info:6,prompt:6,border:2,header:8"
    JOLT_THEME_DESC="terminal default${1:+ ($1)}"
}

# theme_load — set C_RESET C_DIM C_BOLD C_ACCENT C_OK C_WARN C_MUTED
# C_TITLE C_ITA (ANSI strings, empty when colorless), FZF_COLOR_OPT (value
# for fzf --color; "bw" when colorless) and JOLT_THEME_DESC (for --doctor).
# NO_COLOR or THEME=none → colorless. Theme name: CFG_THEME unless "auto",
# else `theme "x"` in $JOLT_ZELLIJ_CONFIG; looked up in that file's
# themes {} block, then in theme_dir (default: themes/ next to the config)
# NAME.kdl first, then every *.kdl. Unknown/unparsable → terminal default.
theme_load() {
    local mode=${CFG_THEME:-auto} name dir f src="" fmt us=$'\x1f' noglob=0
    local fg bg accent green yellow cyan fgd bgp muted
    local -A _th_pal=() _th_fmt=()
    local _th_cfg_name="" _th_cfg_dir="" _th_inblock=0

    C_RESET="" C_DIM="" C_BOLD="" C_ITA=""
    C_ACCENT="" C_OK="" C_WARN="" C_MUTED="" C_TITLE=""
    if [[ -n ${NO_COLOR:-} || $mode == none ]]; then
        FZF_COLOR_OPT=bw
        JOLT_THEME_DESC=none
        return 0
    fi

    [[ $- == *f* ]] && noglob=1
    set -f
    _th_scan "${JOLT_ZELLIJ_CONFIG:-}"
    name=$_th_cfg_name
    [[ $mode != auto ]] && name=$mode
    if [[ -n $name && -z ${_th_fmt[$name]:-} ]]; then
        dir=${_th_cfg_dir:-${JOLT_ZELLIJ_CONFIG%/*}/themes}
        if [[ $dir == "~" ]]; then
            dir=$HOME
        elif [[ $dir == "~/"* ]]; then
            dir="$HOME/${dir#\~/}"
        fi
        set +f
        for f in "$dir/$name.kdl" "$dir"/*.kdl; do
            [[ -f $f ]] || continue
            set -f
            _th_scan "$f"
            set +f
            if [[ -n ${_th_fmt[$name]:-} ]]; then
                src=${f##*/}
                break
            fi
        done
    fi
    ((noglob)) && set -f || set +f

    if [[ -z $name ]]; then
        _th_set_default
        return 0
    fi
    fmt=${_th_fmt[$name]:-}
    if [[ -z $fmt ]]; then
        _th_set_default "theme $name not found"
        return 0
    fi
    fg=${_th_pal[$name${us}fg]:-}
    bg=${_th_pal[$name${us}bg]:-}
    green=${_th_pal[$name${us}green]:-}
    accent=${_th_pal[$name${us}accent]:-${_th_pal[$name${us}accent2]:-$green}}
    if [[ -z $fg || -z $bg || -z $accent ]]; then
        _th_set_default "theme $name unparsable"
        return 0
    fi
    green=${green:-$accent}
    yellow=${_th_pal[$name${us}yellow]:-$accent}
    cyan=${_th_pal[$name${us}cyan]:-${_th_pal[$name${us}blue]:-$accent}}
    _th_mix "$bg" 40
    muted=$REPLY
    _th_mix "$bg" 15
    bgp=$REPLY
    _th_mix "$fg" -10
    fgd=$REPLY

    C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_ITA=$'\e[3m'
    C_ACCENT=$'\e[38;2;'"${accent// /;}m"
    C_OK=$'\e[38;2;'"${green// /;}m"
    C_WARN=$'\e[38;2;'"${yellow// /;}m"
    C_MUTED=$'\e[38;2;'"${muted// /;}m"
    C_TITLE=$'\e[1;38;2;'"${fg// /;}m"

    _th_hex "$bg"
    bg=$REPLY
    _th_hex "$bgp"
    bgp=$REPLY
    _th_hex "$fg"
    fg=$REPLY
    _th_hex "$fgd"
    fgd=$REPLY
    _th_hex "$accent"
    accent=$REPLY
    _th_hex "$yellow"
    yellow=$REPLY
    _th_hex "$cyan"
    cyan=$REPLY
    _th_hex "$muted"
    muted=$REPLY
    FZF_COLOR_OPT="bg:$bg,bg+:$bgp,fg:$fgd,fg+:$fg,hl:$accent,hl+:$accent"
    FZF_COLOR_OPT+=",gutter:$bg,info:$cyan,pointer:$accent,marker:$accent"
    FZF_COLOR_OPT+=",spinner:$yellow,header:$muted,prompt:$cyan,border:$accent"
    FZF_COLOR_OPT+=",preview-bg:$bg,preview-fg:$fgd"

    if [[ $fmt == component ]]; then
        fmt="component format"
    else
        fmt="legacy palette"
    fi
    JOLT_THEME_DESC="$name ($fmt${src:+, $src})"
    return 0
}

# ── data ────────────────────────────────────────────────────────────────

# All parsing here is pure bash (no per-line subshells or external tools):
# sessions_read and meta_read run for every row on each --list/preview.
# Hot-path helpers have underscore twins that return in REPLY.
# Bash 4.2 treats "${arr[@]}" of an empty array as unset under `set -u`,
# hence the ${arr[@]+"${arr[@]}"} idiom below.

# _jolt_now — current epoch in REPLY (JOLT_NOW overrides, for tests).
_jolt_now() {
    if [[ ${JOLT_NOW:-} =~ ^[0-9]+$ ]]; then
        REPLY=$JOLT_NOW
    else
        printf -v REPLY '%(%s)T' -1
    fi
}

# _trim_line LINE — LINE without surrounding whitespace or trailing CR, in REPLY.
_trim_line() {
    local s=${1%$'\r'}
    s=${s#"${s%%[![:space:]]*}"}
    REPLY=${s%"${s##*[![:space:]]}"}
}

# _kdl_str VALUE — decode a KDL string token ("…") in REPLY: outer quotes
# dropped, \" and \\ unescaped, \n \t \r and raw control chars → space so
# the result is always safe inside one TSV field.
_kdl_str() {
    local s=$1 bs='\'
    s=${s#\"}
    s=${s%\"}
    s=${s//[[:cntrl:]]/ }
    s=${s//"$bs$bs"/$'\x01'}
    s=${s//"$bs\""/\"}
    s=${s//"${bs}n"/ }
    s=${s//"${bs}t"/ }
    s=${s//"${bs}r"/ }
    REPLY=${s//$'\x01'/$bs}
}

# sessions_read — parse `zellij list-sessions -n` into lines
# NAME<TAB>STATUS<TAB>AGE, STATUS ∈ active|current|exited. Unparsable
# lines are skipped; a zellij error (e.g. no sessions) yields no output.
sessions_read() {
    local out line st buf=""
    local re='^(.*)\ \[Created\ (.*)\ ago\]\ ?(\((current|EXITED[^)]*)\))?\ *$'
    out=$(zellij list-sessions -n 2>/dev/null) || return 0
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ $line =~ $re ]] || continue
        # A TAB in the name would break this TSV record and the
        # TAB-delimited picker rows.
        [[ ${BASH_REMATCH[1]} == *$'\t'* ]] && continue
        case ${BASH_REMATCH[4]} in
            current) st=current ;;
            EXITED*) st=exited ;;
            *) st=active ;;
        esac
        buf+="${BASH_REMATCH[1]}"$'\t'"$st"$'\t'"${BASH_REMATCH[2]}"$'\n'
    done <<<"$out"
    printf '%s' "$buf"
}

# meta_read NAME — parse $JOLT_CACHE_DIR/NAME/session-metadata.kdl into
#   tab<TAB>POSITION<TAB>ACTIVE<TAB>NAME
#   pane<TAB>TAB_POSITION<TAB>TITLE<TAB>COMMAND
# Only non-plugin, non-suppressed panes are listed; COMMAND is the pane's
# terminal_command or empty. Fields are taken only from tab/pane blocks
# directly under the top-level tabs/panes blocks (brace depth 2), so
# nested history/layout blocks never leak in. Returns 1 if the file is
# missing.
meta_read() {
    local f="$JOLT_CACHE_DIR/$1/session-metadata.kdl"
    local line key val depth=0 top="" blk="" buf=""
    local t_pos t_act t_name p_tab p_title p_cmd p_plugin p_supp
    [[ -n $1 && -f $f && -r $f ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        _trim_line "$line"
        line=$REPLY
        if [[ $line == *'{' ]]; then
            depth=$((depth + 1))
            key=${line%%[[:space:]\{]*}
            if ((depth == 1)); then
                top=$key
            elif ((depth == 2)); then
                blk=$key
                t_pos="" t_act="" t_name=""
                p_tab="" p_title="" p_cmd="" p_plugin="" p_supp=""
            fi
            continue
        fi
        if [[ $line == '}' ]]; then
            if ((depth == 2)); then
                if [[ $top == tabs && $blk == tab ]]; then
                    buf+="tab"$'\t'"$t_pos"$'\t'"${t_act:-false}"$'\t'"$t_name"$'\n'
                elif [[ $top == panes && $blk == pane && $p_plugin == false && $p_supp == false ]]; then
                    buf+="pane"$'\t'"$p_tab"$'\t'"$p_title"$'\t'"$p_cmd"$'\n'
                fi
                blk=""
            fi
            ((depth > 0)) && depth=$((depth - 1))
            continue
        fi
        ((depth == 2)) || continue
        key=${line%%[[:space:]]*}
        val=${line#"$key"}
        val=${val#"${val%%[![:space:]]*}"}
        case "$top/$blk/$key" in
            tabs/tab/position) t_pos=$val ;;
            tabs/tab/active) t_act=$val ;;
            tabs/tab/name)
                _kdl_str "$val"
                t_name=$REPLY
                ;;
            panes/pane/is_plugin) p_plugin=$val ;;
            panes/pane/is_suppressed) p_supp=$val ;;
            panes/pane/tab_position) p_tab=$val ;;
            panes/pane/title)
                _kdl_str "$val"
                p_title=$REPLY
                ;;
            panes/pane/terminal_command)
                _kdl_str "$val"
                p_cmd=$REPLY
                ;;
        esac
    done <"$f"
    printf '%s' "$buf"
}

# layout_cwd NAME — the top-level `cwd "…"` of NAME's cached
# session-layout.kdl, or empty (always succeeds).
layout_cwd() {
    local f="$JOLT_CACHE_DIR/$1/session-layout.kdl" line depth=0
    [[ -n $1 && -f $f && -r $f ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        _trim_line "$line"
        line=$REPLY
        if [[ $line == *'{' ]]; then
            depth=$((depth + 1))
        elif [[ $line == '}' ]]; then
            ((depth > 0)) && depth=$((depth - 1))
        elif ((depth <= 1)) && [[ $line == 'cwd "'* ]]; then
            _kdl_str "${line#cwd }"
            printf '%s\n' "$REPLY"
            return 0
        fi
    done <"$f"
    return 0
}

# state_file mru|pins — path of a state file under $JOLT_STATE_DIR
# (${XDG_STATE_HOME:-~/.local/state}/zellij-jolt). mru holds lines
# EPOCH<TAB>NAME (newest first), pins one NAME per line.
state_file() {
    printf '%s/%s\n' "$JOLT_STATE_DIR" "$1"
}

# _state_ok NAME — NAME is storable (non-empty, no tab or newline).
_state_ok() {
    [[ -n $1 && $1 != *[$'\t\n']* ]]
}

# _state_load KIND — lines of state file KIND into _jolt_state (empty if
# the file is missing/unreadable).
_state_load() {
    _jolt_state=()
    local f="$JOLT_STATE_DIR/$1"
    [[ -f $f && -r $f ]] || return 0
    mapfile -t _jolt_state <"$f"
}

# _state_save KIND — atomically replace state file KIND with _jolt_state:
# write a temp file in the same directory, then rename over the original.
_state_save() {
    local f="$JOLT_STATE_DIR/$1" tmp
    mkdir -p "$JOLT_STATE_DIR" 2>/dev/null || {
        warn "cannot create state dir $JOLT_STATE_DIR"
        return 1
    }
    tmp="$f.tmp.$$.$RANDOM"
    if ! {
        ((${#_jolt_state[@]} == 0)) || printf '%s\n' "${_jolt_state[@]}"
    } >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "cannot write $f"
        return 1
    fi
    mv -f "$tmp" "$f" 2>/dev/null || {
        rm -f "$tmp"
        warn "cannot write $f"
        return 1
    }
}

# state_touch NAME — record NAME as used now (upsert into mru, newest first).
state_touch() {
    local name=$1 l
    local -a keep
    _state_ok "$name" || return 1
    _jolt_now
    keep=("$REPLY"$'\t'"$name")
    _state_load mru
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        [[ ${l#*$'\t'} == "$name" ]] || keep+=("$l")
    done
    _jolt_state=("${keep[@]}")
    _state_save mru
}

# _state_mru NAME — NAME's mru epoch in REPLY, empty if never used.
_state_mru() {
    local l
    REPLY=""
    _state_load mru
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        if [[ $l == *$'\t'* && ${l#*$'\t'} == "$1" ]]; then
            REPLY=${l%%$'\t'*}
            return 0
        fi
    done
}

state_mru() {
    _state_mru "$1"
    [[ -z $REPLY ]] || printf '%s\n' "$REPLY"
}

# _last_used NAME — epoch NAME was last used, in REPLY: mru entry, else the
# mtime of its cache dir, else 0.
_last_used() {
    local d="$JOLT_CACHE_DIR/$1" m=""
    _state_mru "$1"
    [[ -n $REPLY ]] && return 0
    if [[ -n $1 && -e $d ]]; then
        m=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null) || m=""
    fi
    if [[ $m =~ ^[0-9]+$ ]]; then
        REPLY=$m
    else
        REPLY=0
    fi
}

last_used() {
    _last_used "$1"
    printf '%s\n' "$REPLY"
}

# pins_has NAME — succeeds when NAME is pinned (exact match).
pins_has() {
    local l
    _state_load pins
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        [[ $l == "$1" ]] && return 0
    done
    return 1
}

# pins_toggle NAME — pin NAME, or unpin it if already pinned.
pins_toggle() {
    local name=$1 l found=""
    local -a keep=()
    _state_ok "$name" || return 1
    _state_load pins
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        if [[ $l == "$name" ]]; then
            found=1
        else
            keep+=("$l")
        fi
    done
    [[ -n $found ]] || keep+=("$name")
    _jolt_state=(${keep[@]+"${keep[@]}"})
    _state_save pins
}

# _state_edit KIND OLD [NEW] — in state file KIND, replace the entry for
# OLD with NEW (dropping any existing NEW entry), or remove it when NEW is
# empty. The file is only rewritten when OLD was present.
_state_edit() {
    local kind=$1 old=$2 new=${3:-} l n epoch hit=""
    local -a keep=()
    _state_load "$kind"
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        n=$l
        [[ $kind == mru ]] && n=${l#*$'\t'}
        [[ $n == "$old" ]] && hit=1
    done
    [[ -n $hit ]] || return 0
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        n=$l
        [[ $kind == mru ]] && n=${l#*$'\t'}
        if [[ $n == "$old" ]]; then
            [[ -n $new ]] || continue
            if [[ $kind == mru ]]; then
                epoch=${l%%$'\t'*}
                keep+=("$epoch"$'\t'"$new")
            else
                keep+=("$new")
            fi
        elif [[ -z $new || $n != "$new" ]]; then
            keep+=("$l")
        fi
    done
    _jolt_state=(${keep[@]+"${keep[@]}"})
    _state_save "$kind"
}

# state_rename OLD NEW — carry OLD's mru time and pin over to NEW.
state_rename() {
    _state_ok "$1" && _state_ok "$2" || return 1
    [[ $1 == "$2" ]] && return 0
    _state_edit mru "$1" "$2" && _state_edit pins "$1" "$2"
}

# state_forget NAME — drop NAME from mru and pins.
state_forget() {
    _state_ok "$1" || return 1
    _state_edit mru "$1" && _state_edit pins "$1"
}

# _reltime EPOCH — compact age of EPOCH relative to now, in REPLY:
# now, 5m, 3h, 2d, 4w, 3mo, 1y; "?" for 0/empty/invalid.
_reltime() {
    local t=${1:-} d
    if [[ ! $t =~ ^[0-9]+$ ]] || ((10#$t == 0)); then
        REPLY='?'
        return 0
    fi
    _jolt_now
    d=$((REPLY - 10#$t))
    if ((d < 60)); then
        REPLY=now
    elif ((d < 3600)); then
        REPLY="$((d / 60))m"
    elif ((d < 86400)); then
        REPLY="$((d / 3600))h"
    elif ((d < 7 * 86400)); then
        REPLY="$((d / 86400))d"
    elif ((d < 30 * 86400)); then
        REPLY="$((d / (7 * 86400)))w"
    elif ((d < 365 * 86400)); then
        REPLY="$((d / (30 * 86400)))mo"
    else
        REPLY="$((d / (365 * 86400)))y"
    fi
}

reltime() {
    _reltime "${1:-}"
    printf '%s\n' "$REPLY"
}

# ── render ──────────────────────────────────────────────────────────────

# _char_width CODEPOINT — display width of one code point in REPLY
# (0 combining / zero-width / variation selector, 2 East Asian wide or
# emoji, 1 otherwise).
_char_width() {
    local c=$1
    if ((c >= 0x0300 && c <= 0x036F)) ||
        ((c >= 0x200B && c <= 0x200F)) ||
        ((c >= 0x20D0 && c <= 0x20FF)) ||
        ((c >= 0xFE00 && c <= 0xFE0F)); then
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

# The underscore versions return in REPLY without subshells; use them in
# loops. The plain versions echo and are for one-off/CLI use.
# Without a UTF-8 locale (JOLT_UTF8=0) every non-ASCII byte renders as "?"
# so output stays valid and is never cut mid-character.

# _dwidth STR — display width of STR in REPLY.
_dwidth() {
    local s="$1" i c w=0
    if [[ $JOLT_UTF8 != 1 ]]; then
        s=${s//[![:ascii:]]/?}
        REPLY=${#s}
        return
    fi
    if [[ $s != *[![:ascii:]]* ]]; then
        REPLY=${#s}
        return
    fi
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        _char_width "$c"
        w=$((w + REPLY))
    done
    REPLY=$w
}

# _trunc STR W — STR cut to display width <= W in REPLY, ending in "…"
# ("~" without UTF-8) when cut. Also sets _jolt_tw to REPLY's display
# width. Single pass that stops as soon as STR is known not to fit, so
# long titles cost O(W), not O(length).
_trunc() {
    local s="$1" max="$2" i c w=0 cut=-1 cutw=0
    if [[ $JOLT_UTF8 != 1 || $s != *[![:ascii:]]* ]]; then
        [[ $JOLT_UTF8 != 1 ]] && s=${s//[![:ascii:]]/?}
        if ((${#s} <= max)); then
            REPLY=$s
        elif ((max <= 0)); then
            REPLY=""
        elif [[ $JOLT_UTF8 != 1 ]]; then
            REPLY="${s:0:max-1}~"
        else
            REPLY="${s:0:max-1}…"
        fi
        _jolt_tw=${#REPLY}
        return
    fi
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        _char_width "$c"
        w=$((w + REPLY))
        # chars [0,i) are the longest prefix that leaves room for "…"
        ((cut < 0 && w > max - 1)) && cut=$i cutw=$((w - REPLY))
        ((w > max)) && break
    done
    if ((w <= max)); then
        REPLY=$s
        _jolt_tw=$w
    elif ((max <= 0)); then
        REPLY=""
        _jolt_tw=0
    else
        REPLY="${s:0:cut}…"
        _jolt_tw=$((cutw + 1))
    fi
}

# _pad STR W — _trunc STR to W, right-padded with spaces to W, in REPLY.
_pad() {
    local w="$2"
    _trunc "$1" "$w"
    printf -v REPLY '%s%*s' "$REPLY" $((w > _jolt_tw ? w - _jolt_tw : 0)) ""
}

dwidth() {
    _dwidth "$1"
    echo "$REPLY"
}

trunc() {
    _trunc "$1" "$2"
    printf '%s\n' "$REPLY"
}

pad() {
    _pad "$1" "$2"
    printf '%s\n' "$REPLY"
}

# _render_colors_init — make sure every C_* color is set (empty when the
# caller provided only some of them), so render code can use them under
# `set -u`.
_render_colors_init() {
    : "${C_RESET:=}" "${C_DIM:=}" "${C_BOLD:=}" "${C_ACCENT:=}" "${C_OK:=}"
    : "${C_WARN:=}" "${C_MUTED:=}" "${C_TITLE:=}" "${C_ITA:=}"
}

# render_theme — theme_load, unless the picker already exported the result
# (JOLT_THEME_DESC set): fzf runs --list/--preview on every reload and
# cursor move, and parsing the zellij config each time costs ~40ms.
render_theme() {
    if [[ -n ${JOLT_THEME_DESC:-} ]]; then
        _render_colors_init
    else
        theme_load
    fi
}

# _rule N — N box-drawing "─" characters in REPLY.
_rule() {
    printf -v REPLY '%*s' "$1" ""
    REPLY=${REPLY// /─}
}

# _tab_count NAME — number of tabs in NAME's cached metadata, in REPLY
# (0 and return 1 without a cache). Same block rules as meta_read, but
# stops once the top-level tabs block closes: --list needs only the count.
_tab_count() {
    local f="$JOLT_CACHE_DIR/$1/session-metadata.kdl" line depth=0 top="" n=0
    REPLY=0
    [[ -n $1 && -f $f && -r $f ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        if [[ $line == *'{' ]]; then
            depth=$((depth + 1))
            if ((depth == 1)); then
                top=${line%%[[:space:]\{]*}
            elif ((depth == 2)) && [[ $top == tabs && ${line%%[[:space:]\{]*} == tab ]]; then
                n=$((n + 1))
            fi
        elif [[ $line == '}' ]]; then
            ((depth > 0)) && depth=$((depth - 1))
            ((depth == 0)) && [[ $top == tabs ]] && break
        fi
    done <"$f"
    REPLY=$n
}

# rows_build — picker rows KEY<TAB>DISPLAY on stdout: the three action rows
# (a:new, a:project, a:layout), then sessions (s:NAME) ordered pinned,
# active, exited (hidden when SHOW_EXITED=off unless pinned), each newest
# last-used first, and the current session last. DISPLAY is
#   <★|space> <glyph> <name padded to min(longest,28)>  <age padded 4>  <info>
# with glyphs ● active / ○ exited / ◆ current always backed by text
# ("N tabs", "resurrect", "(current)") for NO_COLOR.
# Hot path (every fzf reload): state files are read once, cache dir
# mtimes come from a single stat call, and there are no per-row subshells.
rows_build() {
    local -A mru=() pinned=() mtime=()
    local -a names=() stats=() epochs=() groups=() order=() dirs=()
    local l name st t g i j k maxw=0 w out="" pin glyph info dname stat_out
    _render_colors_init

    _state_load mru
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        [[ $l == *$'\t'* ]] || continue
        name=${l#*$'\t'}
        t=${l%%$'\t'*}
        [[ -n $name && $t =~ ^[0-9]+$ && -z ${mru[$name]+x} ]] && mru[$name]=$((10#$t))
    done
    _state_load pins
    for l in ${_jolt_state[@]+"${_jolt_state[@]}"}; do
        [[ -n $l ]] && pinned[$l]=1
    done

    while IFS=$'\t' read -r name st t; do
        [[ -n $name ]] || continue
        names+=("$name")
        stats+=("$st")
        if [[ -z ${mru[$name]+x} && -n $JOLT_CACHE_DIR && -e $JOLT_CACHE_DIR/$name ]]; then
            dirs+=("$JOLT_CACHE_DIR/$name")
        fi
    done < <(sessions_read)

    # Fallback last-used time: cache dir mtime (GNU stat, else BSD stat).
    if ((${#dirs[@]})); then
        stat_out=$(stat -c $'%Y\t%n' -- "${dirs[@]}" 2>/dev/null)
        [[ -n $stat_out ]] || stat_out=$(stat -f $'%m\t%N' -- "${dirs[@]}" 2>/dev/null)
        while IFS= read -r l; do
            t=${l%%$'\t'*}
            name=${l#*$'\t'}
            name=${name#"$JOLT_CACHE_DIR/"}
            [[ $t =~ ^[0-9]+$ ]] && mtime[$name]=$t
        done <<<"$stat_out"
    fi

    # Group, then insertion-sort by (group asc, last used desc, ls order).
    for ((i = 0; i < ${#names[@]}; i++)); do
        name=${names[i]}
        st=${stats[i]}
        t=${mru[$name]:-${mtime[$name]:-0}}
        if [[ $st == current ]]; then
            g=3
        elif [[ -n ${pinned[$name]+x} ]]; then
            g=0
        elif [[ $st == active ]]; then
            g=1
        else
            [[ ${CFG_SHOW_EXITED:-on} == off ]] && continue
            g=2
        fi
        groups[i]=$g
        epochs[i]=$t
        j=${#order[@]}
        while ((j > 0)); do
            k=${order[j - 1]}
            ((groups[k] > g || (groups[k] == g && epochs[k] < t))) || break
            order[j]=$k
            j=$((j - 1))
        done
        order[j]=$i
        dname=${name//[[:cntrl:]]/?}
        _dwidth "$dname"
        ((REPLY > maxw)) && maxw=$REPLY
    done
    w=$((maxw < 28 ? maxw : 28))

    out+="a:new"$'\t'"${C_MUTED}+ ${C_ITA}new session${C_RESET}"$'\n'
    out+="a:project"$'\t'"${C_MUTED}◇ ${C_ITA}project…${C_RESET}"$'\n'
    out+="a:layout"$'\t'"${C_MUTED}▦ ${C_ITA}new from layout…${C_RESET}"$'\n'
    for i in ${order[@]+"${order[@]}"}; do
        name=${names[i]}
        pin=" "
        [[ -n ${pinned[$name]+x} ]] && pin="${C_WARN}★${C_RESET}"
        case ${stats[i]} in
            current)
                glyph="${C_ACCENT}◆${C_RESET}"
                info="(current)"
                ;;
            exited)
                glyph="${C_MUTED}○${C_RESET}"
                info=resurrect
                ;;
            *)
                glyph="${C_OK}●${C_RESET}"
                info=""
                if _tab_count "$name"; then
                    info="$REPLY tabs"
                    ((REPLY == 1)) && info="1 tab"
                fi
                ;;
        esac
        _pad "${name//[[:cntrl:]]/?}" "$w"
        dname=$REPLY
        _reltime "${epochs[i]}"
        _pad "$REPLY" 4
        out+="s:$name"$'\t'"$pin $glyph $dname  ${C_MUTED}$REPLY  $info${C_RESET}"$'\n'
    done
    printf '%s' "$out"
}

# Preview box helpers. They append to _pv_out using the outer width _pv_w,
# both locals of preview_render (dynamic scope). Every content line is
# "│ " + text padded to _pv_w-4 + " │", so all lines share one display
# width regardless of wide or multibyte characters.

# _pv_edge LEFT RIGHT [TITLE] — a horizontal edge, TITLE inset after "─ ".
_pv_edge() {
    local t=${3:-}
    if [[ -n $t ]]; then
        _trunc "${t//[[:cntrl:]]/?}" $((_pv_w - 6))
        t=$REPLY
        _dwidth "$t"
        _rule $((_pv_w - 5 - REPLY))
        _pv_out+="${C_ACCENT}$1─ ${C_RESET}${C_TITLE}$t${C_RESET}${C_ACCENT} $REPLY$2${C_RESET}"$'\n'
    else
        _rule $((_pv_w - 2))
        _pv_out+="${C_ACCENT}$1$REPLY$2${C_RESET}"$'\n'
    fi
}

# _pv_row PREFIX TEXT [PREFIX_COLOR [TEXT_COLOR]] — one content line.
# PREFIX must be narrower than the inner width (labels, tree glyphs).
_pv_row() {
    local p=$1 pc=${3:-} tc=${4:-} pw
    _dwidth "$p"
    pw=$REPLY
    _pad "${2//[[:cntrl:]]/ }" $((_pv_w - 4 - pw))
    _pv_out+="${C_ACCENT}│${C_RESET} $pc$p${pc:+$C_RESET}$tc$REPLY${tc:+$C_RESET} ${C_ACCENT}│${C_RESET}"$'\n'
}

# _pv_kv LABEL VALUE [VALUE_COLOR] — "label     value" header row.
_pv_kv() {
    local l
    printf -v l '%-10s' "$1"
    _pv_row "$l" "$2" "$C_MUTED" "${3:-}"
}

# _pv_wrap TEXT [COLOR] — TEXT word-wrapped over as many rows as needed.
_pv_wrap() {
    local inner=$((_pv_w - 4)) word line="" lw=0 ww
    local -a words=()
    read -r -a words <<<"$1"
    for word in ${words[@]+"${words[@]}"}; do
        _dwidth "$word"
        ww=$REPLY
        if [[ -z $line ]]; then
            line=$word lw=$ww
        elif ((lw + 1 + ww > inner)); then
            _pv_row "" "$line" "" "${2:-}"
            line=$word lw=$ww
        else
            line+=" $word"
            lw=$((lw + 1 + ww))
        fi
    done
    [[ -z $line ]] || _pv_row "" "$line" "" "${2:-}"
}

# _pv_session NAME — header (status, created, last used, pinned, cwd), then
# the cached tabs (1-based, ▸ active) with up to 3 deduped panes each.
_pv_session() {
    local name=$1 n s a st="" age="" t cwd h meta l kind b c text pos
    local -a tnames=() tact=()
    local -A seen=() plist=() pcount=()

    while IFS=$'\t' read -r n s a; do
        if [[ $n == "$name" ]]; then
            st=$s age=$a
            break
        fi
    done < <(sessions_read)
    _pv_edge ╭ ╮ "${name:-?}"
    if [[ -z $name || -z $st ]]; then
        _pv_row "" "session not found" "" "$C_WARN"
        _pv_edge ╰ ╯
        return 0
    fi

    case $st in
        current) _pv_kv status "◆ current" "$C_ACCENT" ;;
        exited) _pv_kv status "○ exited" "$C_MUTED" ;;
        *) _pv_kv status "● active" "$C_OK" ;;
    esac
    _pv_kv created "$age ago"
    _last_used "$name"
    _reltime "$REPLY"
    t=$REPLY
    [[ $t == now || $t == '?' ]] || t+=" ago"
    _pv_kv "last used" "$t"
    pins_has "$name" && _pv_kv pinned yes "$C_WARN"
    cwd=$(layout_cwd "$name")
    if [[ -n $cwd ]]; then
        h=${HOME:-}
        h=${h%/}
        if [[ -n $h ]]; then
            # A literal ~ is the point here (display only).
            if [[ $cwd == "$h" ]]; then
                # shellcheck disable=SC2088
                cwd="~"
            elif [[ $cwd == "$h"/* ]]; then
                # shellcheck disable=SC2088
                cwd="~/${cwd#"$h"/}"
            fi
        fi
        _pv_kv cwd "$cwd"
    fi
    _pv_edge ├ ┤

    if ! meta=$(meta_read "$name"); then
        _pv_row "" "no cached layout yet" "" "$C_MUTED"
        _pv_edge ╰ ╯
        return 0
    fi
    # Records: tab POS ACTIVE NAME / pane TAB TITLE CMD (fields may be
    # empty, so split by hand rather than with IFS=TAB read).
    while IFS= read -r l; do
        [[ $l == *$'\t'*$'\t'*$'\t'* ]] || continue
        kind=${l%%$'\t'*}
        l=${l#*$'\t'}
        a=${l%%$'\t'*}
        l=${l#*$'\t'}
        b=${l%%$'\t'*}
        c=${l#*$'\t'}
        [[ $a =~ ^[0-9]+$ ]] || continue
        a=$((10#$a))
        if [[ $kind == tab ]]; then
            tnames[a]=$c
            tact[a]=$b
            continue
        fi
        text=${b:-$c}
        [[ -n $c && $c != "$b" && -n $b ]] && text+=" — $c"
        [[ -n ${seen[$a$'\x1f'$text]+x} ]] && continue
        seen[$a$'\x1f'$text]=1
        pcount[$a]=$((${pcount[$a]:-0} + 1))
        ((${pcount[$a]} <= 3)) && plist[$a]+="$text"$'\x1e'
    done <<<"$meta"

    n=0
    for pos in ${tnames[@]+"${!tnames[@]}"}; do
        n=$((n + 1))
        if [[ ${tact[pos]:-} == true ]]; then
            _pv_row "▸ " "$n. ${tnames[pos]}" "$C_ACCENT" "$C_BOLD"
        else
            _pv_row "  " "$n. ${tnames[pos]}"
        fi
        l=${plist[$pos]:-}
        while [[ -n $l ]]; do
            _pv_row "    └ " "${l%%$'\x1e'*}" "$C_MUTED"
            l=${l#*$'\x1e'}
        done
        c=${pcount[$pos]:-0}
        ((c > 3)) && _pv_row "    └ " "+$((c - 3)) more" "$C_MUTED" "$C_MUTED"
    done
    ((n)) || _pv_row "" "no tabs cached" "" "$C_MUTED"
    _pv_edge ╰ ╯
}

# preview_render KEY — the fzf preview for a row key, as a box exactly
# ${FZF_PREVIEW_COLUMNS:-60}-2 columns wide (min 20): session details for
# s:NAME, short help for a:new / a:project / a:layout.
preview_render() {
    local key=${1:-} cols=${FZF_PREVIEW_COLUMNS:-60} _pv_w _pv_out=""
    _render_colors_init
    [[ $cols =~ ^[0-9]{1,4}$ ]] || cols=60
    _pv_w=$((10#$cols - 2))
    ((_pv_w < 20)) && _pv_w=20
    case $key in
        s:*)
            _pv_session "${key#s:}"
            ;;
        a:new)
            _pv_edge ╭ ╮ "new session"
            _pv_wrap "Create a session named after the query: type a name and press enter. ${CFG_KEY_CREATE:-alt-enter} creates from the query even when it matches a row."
            _pv_row "" ""
            _pv_wrap "Inside zellij this switches to the new session; outside it attaches to it." "$C_MUTED"
            _pv_edge ╰ ╯
            ;;
        a:project)
            _pv_edge ╭ ╮ "project"
            _pv_wrap "Open a project directory as a session (${CFG_KEY_PROJECT:-ctrl-o})."
            _pv_row "" ""
            _pv_wrap "Candidates come from zoxide, else git repositories under PROJECT_ROOTS. A session already named after the project is reused." "$C_MUTED"
            _pv_edge ╰ ╯
            ;;
        a:layout)
            _pv_edge ╭ ╮ "layout"
            _pv_wrap "Start a new session from a layout (${CFG_KEY_LAYOUT:-ctrl-l}), then name it."
            _pv_row "" ""
            _pv_wrap "Lists your layouts in ~/.config/zellij/layouts plus the built-ins default, compact, classic and strider." "$C_MUTED"
            _pv_edge ╰ ╯
            ;;
        *)
            _pv_edge ╭ ╮ "zellij-jolt"
            _pv_row "" "nothing to preview" "" "$C_MUTED"
            _pv_edge ╰ ╯
            ;;
    esac
    printf '%s' "$_pv_out"
}

# ── actions ─────────────────────────────────────────────────────────────

# _bytelen STR — byte length (not character length) of STR.
_bytelen() {
    local LC_ALL=C
    echo "${#1}"
}

# sanitize_name STR — session-safe name: control chars dropped, "/" → "-",
# whitespace runs → "-", trimmed of spaces and leading/trailing "-", capped
# at 48 bytes (zellij socket path limit) on a character boundary. Returns 1 when nothing is left.
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
    while [[ $out == -* ]]; do out=${out#-}; done
    while (($(_bytelen "$out") > 48)); do
        out=${out%?}
    done
    while [[ $out == *- ]]; do out=${out%-}; done
    [[ -n $out ]] || return 1
    printf '%s\n' "$out"
}

# run_or_exec ARGV… — replace this process with ARGV, or with JOLT_DRY_RUN=1
# print it shell-quoted ("DRY: …") and return 0.
run_or_exec() {
    local q
    if [[ ${JOLT_DRY_RUN:-} == 1 ]]; then
        printf -v q '%q ' "$@"
        printf 'DRY: %s\n' "${q% }"
        return 0
    fi
    # execfail: a failed exec returns here instead of killing the script.
    shopt -s execfail
    exec "$@"
    die "cannot run $1"
}

# session_exists NAME — succeeds when `zellij list-sessions -s` has an
# exact NAME line (active or exited).
session_exists() {
    local out line
    [[ -n ${1:-} ]] || return 1
    out=$(zellij list-sessions -s 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ ${line%$'\r'} == "$1" ]] && return 0
    done <<<"$out"
    return 1
}

# _session_status NAME — NAME's status (active|current|exited) from
# sessions_read in REPLY; returns 1 (REPLY empty) when NAME is not listed.
_session_status() {
    local line
    REPLY=""
    while IFS= read -r line; do
        [[ ${line%%$'\t'*} == "$1" ]] || continue
        line=${line#*$'\t'}
        REPLY=${line%%$'\t'*}
        return 0
    done < <(sessions_read)
    return 1
}

# _key_name KEY — session name of a row key "s:NAME" in REPLY; returns 1
# for action rows (a:…) and anything else.
_key_name() {
    REPLY=""
    [[ ${1:-} == s:?* ]] || return 1
    REPLY=${1#s:}
}

# _tty_read PROMPT — print PROMPT on the terminal and read one line from it
# into REPLY. The terminal is $JOLT_TTY (default /dev/tty; tests point it at
# a file). Returns 1 when it cannot be opened or read.
_tty_read() {
    local tty=${JOLT_TTY:-/dev/tty} ans=""
    REPLY=""
    [[ -r $tty ]] || return 1
    if [[ -w $tty && $tty == /dev/tty ]]; then
        printf '%s' "$1" 2>/dev/null >"$tty"
    else
        printf '%s' "$1" >&2
    fi
    { IFS= read -r ans <"$tty"; } 2>/dev/null || [[ -n $ans ]] || return 1
    REPLY=$ans
}

# confirm PROMPT — ask y/N on the terminal. Yes without asking when
# JOLT_ASSUME_YES=1 or CONFIRM_DELETE=off; no terminal means no.
confirm() {
    [[ ${JOLT_ASSUME_YES:-} == 1 || ${CFG_CONFIRM_DELETE:-on} == off ]] && return 0
    _tty_read "$1 [y/N] " || return 1
    [[ $REPLY =~ ^[[:space:]]*([Yy]|[Yy][Ee][Ss])[[:space:]]*$ ]]
}

# go NAME [CWD] [LAYOUT] — the single exit door: switch to, attach to or
# create NAME. Inside zellij it switches sessions (switch-session also
# creates a missing session; LAYOUT only applies then). Outside it attaches
# to an existing session or creates a new one in CWD, with LAYOUT if given.
# The final command goes through run_or_exec (printed under --dry-run).
go() {
    local name=${1:-} cwd=${2:-} layout=${3:-} new=""
    local -a argv
    [[ -n $name ]] || {
        warn "no session name given"
        return 1
    }
    session_exists "$name" || new=1
    if [[ -n ${ZELLIJ:-} ]]; then
        if [[ $name == "${ZELLIJ_SESSION_NAME:-}" ]]; then
            printf 'already in %s\n' "$name"
            return 0
        fi
        state_touch "$name" || true
        # Options first, then `--` so a name starting with "-" stays a name.
        argv=(zellij action switch-session)
        [[ -n $cwd ]] && argv+=(--cwd "$cwd")
        [[ -n $new && -n $layout ]] && argv+=(--layout "$layout")
        argv+=(-- "$name")
        run_or_exec "${argv[@]}"
        return
    fi
    state_touch "$name" || true
    if [[ -z $new ]]; then
        run_or_exec zellij attach "$name"
        return
    fi
    if [[ -n $cwd ]]; then
        [[ -d $cwd ]] || {
            warn "no such directory: $cwd"
            return 1
        }
        if [[ ${JOLT_DRY_RUN:-} == 1 ]]; then
            printf 'DRY: cd %s\n' "$cwd"
        else
            cd -- "$cwd" || {
                warn "cannot cd to $cwd"
                return 1
            }
        fi
    fi
    if [[ -n $layout ]]; then
        run_or_exec zellij -n "$layout" -s "$name"
    else
        run_or_exec zellij attach -c "$name"
    fi
}

# act_delete KEY — kill (if running) and delete session "s:NAME" after a
# confirm. Refuses the current session. A session that is already gone
# (kill rc 1, delete rc 2, or not listed) counts as success. Forgets NAME's
# mru/pin entries.
act_delete() {
    local name st rc
    _key_name "${1:-}" || return 0
    name=$REPLY
    if [[ $name == "${ZELLIJ_SESSION_NAME:-}" ]]; then
        warn "refusing to delete the current session ($name)"
        return 1
    fi
    if ! _session_status "$name"; then
        state_forget "$name" || true
        return 0
    fi
    st=$REPLY
    case $st in
        current)
            warn "refusing to delete the current session ($name)"
            return 1
            ;;
        active)
            confirm "Kill and delete $name?" || return 0
            zellij kill-session -- "$name" >/dev/null 2>&1
            rc=$?
            if ((rc != 0 && rc != 1)); then
                warn "kill-session $name failed (rc $rc)"
                return 1
            fi
            ;;
        *)
            confirm "Delete $name?" || return 0
            ;;
    esac
    zellij delete-session -f -- "$name" >/dev/null 2>&1
    rc=$?
    if ((rc != 0 && rc != 2)); then
        warn "delete-session $name failed (rc $rc)"
        return 1
    fi
    state_forget "$name" || true
    return 0
}

# act_purge — after one confirm, delete every exited session.
act_purge() {
    local line rc fail=0
    local -a exited=()
    while IFS= read -r line; do
        [[ $line == *$'\texited\t'* ]] && exited+=("${line%%$'\t'*}")
    done < <(sessions_read)
    if ((${#exited[@]} == 0)); then
        printf 'no exited sessions\n'
        return 0
    fi
    confirm "Delete ${#exited[@]} exited sessions?" || return 0
    for line in "${exited[@]}"; do
        zellij delete-session -f -- "$line" >/dev/null 2>&1
        rc=$?
        if ((rc != 0 && rc != 2)); then
            warn "delete-session $line failed (rc $rc)"
            fail=1
            continue
        fi
        state_forget "$line" || true
    done
    return "$fail"
}

# act_rename KEY — rename running session "s:NAME". The new name comes from
# $JOLT_RENAME_TO or a terminal prompt (empty answer cancels; unusable names
# re-prompt, up to 3 tries) and is sanitized. Exited sessions can't be renamed by zellij.
act_rename() {
    local old new raw rc tries=0
    _key_name "${1:-}" || return 0
    old=$REPLY
    if ! _session_status "$old"; then
        warn "no session named $old"
        return 1
    fi
    if [[ $REPLY == exited ]]; then
        warn "zellij can only rename running sessions ($old is exited)"
        return 1
    fi
    while :; do
        if ((++tries > 3)); then
            warn "too many unusable names; rename cancelled"
            return 1
        fi
        if [[ -n ${JOLT_RENAME_TO+x} ]]; then
            raw=$JOLT_RENAME_TO
        else
            _tty_read "Rename $old to: " || return 0
            raw=$REPLY
        fi
        _trim_line "$raw"
        [[ -n $REPLY ]] || return 0
        if new=$(sanitize_name "$raw"); then
            break
        fi
        warn "unusable session name: $raw"
        [[ -n ${JOLT_RENAME_TO+x} ]] && return 1
    done
    [[ $new == "$old" ]] && return 0
    if session_exists "$new"; then
        warn "a session named $new already exists"
        return 1
    fi
    zellij --session="$old" action rename-session -- "$new" >/dev/null 2>&1
    rc=$?
    if ((rc != 0)); then
        warn "rename-session failed (rc $rc)"
        return 1
    fi
    state_rename "$old" "$new" || true
    return 0
}

# act_pin KEY — toggle the pin on session "s:NAME".
act_pin() {
    _key_name "${1:-}" || return 0
    pins_toggle "$REPLY"
}

# action_dispatch ACT [KEY] — the --action handler. rc 2 for unknown ACT.
action_dispatch() {
    case "${1:-}" in
        delete) act_delete "${2:-}" ;;
        purge) act_purge ;;
        rename) act_rename "${2:-}" ;;
        pin) act_pin "${2:-}" ;;
        *) return 2 ;;
    esac
}

# _doctor_tool NAME MIN — print "NAME VERSION (ok|too old, need >= MIN)" or
# "NAME missing (need >= MIN)"; returns 1 unless the floor is met.
_doctor_tool() {
    local out v
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s missing (need >= %s)\n' "$1" "$2"
        return 1
    fi
    out=$("$1" --version 2>/dev/null) || out=""
    out=${out%%$'\n'*}
    v=${out#"$1 "}
    v=${v%% *}
    if [[ -n $v ]] && (($(ver_to_int "$v") >= $(ver_to_int "$2"))); then
        printf '%s %s (ok)\n' "$1" "$v"
        return 0
    fi
    printf '%s %s (too old, need >= %s)\n' "$1" "${v:-unknown}" "$2"
    return 1
}

# doctor — environment diagnostics. rc 0 when bash, fzf and zellij meet
# the floors, else 1. Missing optional tools never fail it.
doctor() {
    local rc=0 have t
    have="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
    if (($(ver_to_int "$have") >= $(ver_to_int "$JOLT_MIN_BASH"))); then
        printf 'bash %s (ok)\n' "$have"
    else
        printf 'bash %s (too old, need >= %s)\n' "$have" "$JOLT_MIN_BASH"
        rc=1
    fi
    _doctor_tool fzf "$JOLT_MIN_FZF" || rc=1
    _doctor_tool zellij "$JOLT_MIN_ZELLIJ" || rc=1
    if [[ -d $JOLT_CACHE_DIR ]]; then
        printf 'cache dir %s\n' "$JOLT_CACHE_DIR"
    else
        printf 'cache dir %s (missing)\n' "$JOLT_CACHE_DIR"
    fi
    config_load 2>/dev/null
    theme_load
    printf 'theme %s\n' "${JOLT_THEME_DESC:-unknown}"
    for t in zoxide fd; do
        if command -v "$t" >/dev/null 2>&1 || { [[ $t == fd ]] && command -v fdfind >/dev/null 2>&1; }; then
            printf '%s found\n' "$t"
        else
            printf '%s missing\n' "$t"
        fi
    done
    if [[ -f $JOLT_CONFIG_FILE ]]; then
        printf 'config %s\n' "$JOLT_CONFIG_FILE"
    else
        printf 'config %s (not found, using defaults)\n' "$JOLT_CONFIG_FILE"
    fi
    printf 'state %s\n' "$JOLT_STATE_DIR"
    return "$rc"
}

# (Task: pick_project, pick_layout.)

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
            config_load
            render_theme
            rows_build
            ;;
        --preview)
            (($# >= 2)) || _usage_error "--preview needs a KEY"
            config_load
            render_theme
            preview_render "$2"
            ;;
        --action)
            (($# >= 2)) || _usage_error "--action needs ACT and KEY"
            case $2 in
                delete | rename | pin | purge) ;;
                *) _usage_error "unknown action: $2 (delete|rename|pin|purge)" ;;
            esac
            [[ $2 == purge || $# -ge 3 ]] || _usage_error "--action $2 needs a KEY"
            config_load
            action_dispatch "$2" "${3:-}"
            exit $?
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
            doctor
            exit $?
            ;;
        *)
            _usage_error "unknown option: $1"
            ;;
    esac
}

[[ ${JOLT_NO_MAIN:-} == 1 ]] || main "$@"
