#!/usr/bin/env bats
# Picker: fzf invocation, result dispatch, project and layout sub-pickers.
# fzf is replaced by test/stubs/fzf-scripted (JOLT_FZF), so every test is
# non-interactive; JOLT_TEST_TTY=1 skips the terminal check and prompts
# read $JOLT_TTY (a file) instead of the real terminal.

setup() {
  load test_helper
  jolt_setup
  use_ls mixed
  JOLT_DRY_RUN=1
  export JOLT_FZF="$REPO/test/stubs/fzf-scripted" JOLT_NO_FALLBACK=1 JOLT_TEST_TTY=1
  export JOLT_TTY="$BATS_TEST_TMPDIR/tty"
  export FZF_SCRIPT_ARGS="$BATS_TEST_TMPDIR/fzf.args"
  unset FZF_SCRIPT_DIR FZF_SCRIPT_OUT FZF_SCRIPT_RC JOLT_ASSUME_YES FZF_DEFAULT_OPTS
  # a zoxide that knows nothing, so project roots are used
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/zoxide"
  chmod +x "$BATS_TEST_TMPDIR/bin/zoxide"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

pick() { FZF_SCRIPT_OUT="$1" FZF_SCRIPT_RC="$2" run "$REPO/zellij-jolt.sh" --dry-run </dev/null; }

# script N OUT [RC] — sequence mode: the Nth fzf call prints OUT, exits RC.
script() {
  export FZF_SCRIPT_DIR="$BATS_TEST_TMPDIR/fzf"
  mkdir -p "$FZF_SCRIPT_DIR"
  printf '%s\n' "$2" >"$FZF_SCRIPT_DIR/$1.out"
  echo "${3:-0}" >"$FZF_SCRIPT_DIR/$1.rc"
}

# cfg LINE... — write the zellij-jolt config file.
cfg() {
  mkdir -p "$XDG_CONFIG_HOME/zellij-jolt"
  printf '%s\n' "$@" >"$XDG_CONFIG_HOME/zellij-jolt/config"
}

# fzf_arg N PATTERN — call N's argv (one arg per line) has a line matching PATTERN.
fzf_args() {
  sed -n "${1}p" "$FZF_SCRIPT_ARGS" | tr '\037' '\n'
}

@test "esc exits 0" {
  pick "" 130
  assert_success
  refute_output --partial DRY
}

@test "enter on session attaches" {
  pick $'\n\ns:appr\t  ● appr' 0
  assert_success
  assert_output --partial "zellij attach appr"
}

@test "no match with query creates" {
  pick $'newproj' 1
  assert_success
  assert_output --partial "zellij attach -c newproj"
}

@test "alt-enter forces create" {
  pick $'app\nalt-enter\ns:appr\tx' 0
  assert_success
  assert_output --partial "attach -c app"
}

@test "query is sanitized before create" {
  pick $'my new/proj' 1
  assert_output --partial "attach -c my-new-proj"
}

@test "names with spaces attach quoted" {
  pick $'\n\ns:my proj (x)\tx' 0
  assert_output --partial 'zellij attach my\ proj\ \(x\)'
}

@test "no match without query loops, then esc exits 0" {
  script 1 "" 1
  script 2 "" 130
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_success
  [ "$(cat "$FZF_SCRIPT_DIR/n")" = 2 ]
  refute_output --partial DRY
}

@test "fzf rc 2 warns and falls back" {
  pick "" 2
  assert_failure 1
  assert_output --partial "fzf"
}

@test "new-session row uses the query" {
  pick $'fresh\n\na:new\tx' 0
  assert_output --partial "attach -c fresh"
}

@test "new-session row without query prompts for a name" {
  echo "prompted name" >"$JOLT_TTY"
  pick $'\n\na:new\tx' 0
  assert_output --partial "attach -c prompted-name"
}

@test "new-session row with empty name lets zellij pick one" {
  echo "" >"$JOLT_TTY"
  pick $'\n\na:new\tx' 0
  assert_output --partial "DRY: zellij"
  refute_output --partial "attach"
}

@test "inside zellij: enter on current says already in, exits 0" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian pick $'\n\ns:obsidian\tx' 0
  assert_success
  assert_output --partial "already in obsidian"
}

@test "inside zellij: enter on other session switches" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian pick $'\n\ns:appr\tx' 0
  assert_output --partial "zellij action switch-session -- appr"
}

@test "fzf gets expect keys, quoted callbacks and the theme colors" {
  pick "" 130
  run fzf_args 1
  assert_line "--expect=alt-enter,ctrl-o,ctrl-l"
  assert_line "--print-query"
  assert_line --regexp "^--color="
  local q
  printf -v q '%q' "$REPO/zellij-jolt.sh"
  assert_line "$q --preview {1}"
  assert_line --partial "ctrl-d:execute"
  assert_line --partial "$q --action delete {1}"
  assert_line --partial "reload"
  assert_line --partial "ctrl-t:execute-silent"
  assert_line "ctrl-/:toggle-preview"
  assert_line --partial "?:preview"
  assert_line --regexp '^right:55%:wrap'
}

@test "real fzf with the base options searches the displayed names" {
  command -v fzf >/dev/null || skip "fzf not installed"
  jolt_source
  unset JOLT_FZF
  NO_COLOR=1 theme_load
  fzf_base_opts
  run fzf "${FZF_OPTS[@]}" --filter=memora < <(rows_build)
  assert_success
  assert_output --regexp $'^s:memora_new\t'
}

@test "with-shell is passed when fzf supports it" {
  pick "" 130
  run fzf_args 1
  assert_line "--with-shell=bash -c"
}

@test "PREVIEW=off starts with the preview hidden" {
  cfg PREVIEW=off PREVIEW_POS=bottom
  pick "" 130
  run fzf_args 1
  assert_line --regexp '^bottom:55%:wrap.*hidden'
}

@test "custom keys are used; invalid ones fall back to the default" {
  cfg 'KEY_DELETE=alt-x' 'KEY_PIN=ctrl-t,abort' 'KEY_CREATE=ctrl-e:accept'
  pick "" 130
  assert_output --partial "KEY_PIN"
  assert_output --partial "KEY_CREATE"
  run fzf_args 1
  assert_line --partial "alt-x:execute"
  assert_line --partial "ctrl-t:execute-silent"
  assert_line "--expect=alt-enter,ctrl-o,ctrl-l"
}

@test "an overridden key that is reserved or taken falls back to its default" {
  cfg 'KEY_PIN=ctrl-o' 'KEY_RENAME=ctrl-j' 'KEY_PURGE=alt-p'
  jolt_source
  run config_load
  assert_output --partial "KEY_PIN=ctrl-o is also bound to KEY_PROJECT (using ctrl-t)"
  assert_output --partial "KEY_RENAME=ctrl-j is reserved (using ctrl-r)"
  config_load 2>/dev/null
  [ "$CFG_KEY_PIN" = ctrl-t ]
  [ "$CFG_KEY_RENAME" = ctrl-r ]
  [ "$CFG_KEY_PURGE" = alt-p ]
  [ "$CFG_KEY_PROJECT" = ctrl-o ]
}

@test "a clash with a default key that cannot be resolved is only warned about" {
  # PURGE falls back to alt-d, which DELETE (checked earlier) now holds.
  cfg 'KEY_DELETE=alt-d' 'KEY_PURGE=ctrl-r'
  jolt_source
  run config_load
  assert_output --partial "KEY_PURGE=ctrl-r is also bound to KEY_RENAME (using alt-d)"
  assert_output --partial "KEY_PURGE=alt-d is also bound to KEY_DELETE"
  config_load 2>/dev/null
  [ "$CFG_KEY_DELETE" = alt-d ]
  [ "$CFG_KEY_PURGE" = alt-d ]
}

@test "default keys raise no warnings" {
  jolt_source
  run config_load
  assert_success
  assert_output ""
}

@test "help preview lists every key" {
  run "$REPO/zellij-jolt.sh" --preview a:help
  assert_success
  for k in enter alt-enter ctrl-d alt-d ctrl-r ctrl-t ctrl-o ctrl-l 'ctrl-/' '?' esc; do
    assert_output --partial "$k"
  done
}

@test "--help mentions every key and flag" {
  run "$REPO/zellij-jolt.sh" --help
  for k in alt-enter ctrl-d alt-d ctrl-r ctrl-t ctrl-o ctrl-l 'ctrl-/' --list --preview --action --dry-run --init-shell --doctor --version --preview-dir; do
    assert_output --partial -- "$k"
  done
}

# ── projects ────────────────────────────────────────────────────────────

mkproj() {
  mkdir -p "$BATS_TEST_TMPDIR/p/$1/.git"
}

@test "project_candidates finds git repos under PROJECT_ROOTS" {
  mkproj alpha
  mkproj "deep/beta"
  mkdir -p "$BATS_TEST_TMPDIR/p/notrepo"
  cfg "PROJECT_ROOTS=$BATS_TEST_TMPDIR/p $BATS_TEST_TMPDIR/missing" PROJECT_DEPTH=3
  jolt_source
  config_load
  run project_candidates
  assert_success
  assert_line "$BATS_TEST_TMPDIR/p/alpha"
  assert_line "$BATS_TEST_TMPDIR/p/deep/beta"
  refute_line --partial notrepo
}

@test "project_candidates prefers zoxide, existing dirs only" {
  mkdir -p "$BATS_TEST_TMPDIR/z1"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" "/nonexistent/zz"\n' "$BATS_TEST_TMPDIR/z1" >"$BATS_TEST_TMPDIR/bin/zoxide"
  jolt_source
  config_load
  run project_candidates
  assert_output "$BATS_TEST_TMPDIR/z1"
}

@test "project_session_name uses the repo top level" {
  jolt_source
  mkdir -p "$BATS_TEST_TMPDIR/My Repo/sub"
  run project_session_name "$BATS_TEST_TMPDIR/My Repo/sub"
  assert_output "sub"
  git -C "$BATS_TEST_TMPDIR/My Repo" init -q
  run project_session_name "$BATS_TEST_TMPDIR/My Repo/sub"
  assert_output "My-Repo"
}

@test "ctrl-o opens the project picker and creates in the dir" {
  mkproj alpha
  cfg "PROJECT_ROOTS=$BATS_TEST_TMPDIR/p"
  script 1 $'\nctrl-o\n'
  script 2 "$BATS_TEST_TMPDIR/p/alpha"$'\t~/p/alpha'
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_success
  assert_output --partial "DRY: cd $BATS_TEST_TMPDIR/p/alpha"
  assert_output --partial "zellij attach -c alpha"
  run fzf_args 2
  assert_line --partial -- "--preview-dir {1}"
}

@test "project row uses DEFAULT_LAYOUT for new sessions" {
  mkproj alpha
  cfg "PROJECT_ROOTS=$BATS_TEST_TMPDIR/p" DEFAULT_LAYOUT=compact
  script 1 $'\n\na:project\tx'
  script 2 "$BATS_TEST_TMPDIR/p/alpha"$'\tx'
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_output --partial "zellij -n compact -s alpha"
}

@test "esc in the project picker returns to the main picker" {
  mkproj alpha
  cfg "PROJECT_ROOTS=$BATS_TEST_TMPDIR/p"
  script 1 $'\nctrl-o\n'
  script 2 "" 130
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_success
  [ "$(cat "$FZF_SCRIPT_DIR/n")" = 3 ]
  refute_output --partial DRY
}

@test "--preview-dir lists the directory" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  touch "$BATS_TEST_TMPDIR/d/hello.txt" "$BATS_TEST_TMPDIR/d/.hidden"
  run "$REPO/zellij-jolt.sh" --preview-dir "$BATS_TEST_TMPDIR/d"
  assert_success
  assert_output --partial hello.txt
  assert_output --partial .hidden
}

# ── layouts ─────────────────────────────────────────────────────────────

@test "layout_candidates: user layouts plus built-ins, deduped" {
  mkdir -p "$BATS_TEST_TMPDIR/layouts"
  touch "$BATS_TEST_TMPDIR/layouts/dev.kdl" "$BATS_TEST_TMPDIR/layouts/compact.kdl" "$BATS_TEST_TMPDIR/layouts/dev.swap.kdl"
  jolt_source
  run layout_candidates
  assert_output $'compact\ndev\ndefault\nclassic\nstrider'
}

@test "layout_candidates includes layout_dir from the zellij config" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$BATS_TEST_TMPDIR/rel/lay" "$HOME/lay" "$BATS_TEST_TMPDIR/layouts"
  touch "$BATS_TEST_TMPDIR/rel/lay/mine.kdl" "$BATS_TEST_TMPDIR/rel/lay/compact.kdl" \
    "$BATS_TEST_TMPDIR/layouts/mine.kdl" "$BATS_TEST_TMPDIR/layouts/other.kdl" "$HOME/lay/tilde.kdl"
  jolt_source
  # relative to the config file's directory, deduped with layouts/ and built-ins
  printf 'theme "x"\nlayout_dir "rel/lay"\n' >"$JOLT_ZELLIJ_CONFIG"
  run layout_candidates
  assert_output $'compact\nmine\nother\ndefault\nclassic\nstrider'
  # ~ expansion
  printf 'layout_dir "~/lay"\n' >"$JOLT_ZELLIJ_CONFIG"
  run layout_candidates
  assert_output $'tilde\nmine\nother\ndefault\ncompact\nclassic\nstrider'
  # absolute
  printf 'layout_dir "%s/rel/lay"\n' "$BATS_TEST_TMPDIR" >"$JOLT_ZELLIJ_CONFIG"
  run layout_candidates
  assert_line --index 0 compact
  assert_line --index 1 mine
}

@test "ctrl-l picks a layout then prompts for the name" {
  echo "my lay" >"$JOLT_TTY"
  script 1 $'\nctrl-l\n'
  script 2 $'strider\tstrider'
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_success
  assert_output --partial "zellij -n strider -s my-lay"
}

@test "layout name prompt defaults to the query" {
  echo "" >"$JOLT_TTY"
  script 1 $'web\nctrl-l\n'
  script 2 $'compact\tcompact'
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_output --partial "zellij -n compact -s web"
}

@test "empty layout name cancels back to the main picker" {
  : >"$JOLT_TTY"
  script 1 $'\n\na:layout\tx'
  script 2 $'compact\tcompact'
  run "$REPO/zellij-jolt.sh" --dry-run </dev/null
  assert_success
  refute_output --partial DRY
  [ "$(cat "$FZF_SCRIPT_DIR/n")" = 3 ]
}
