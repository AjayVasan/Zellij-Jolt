#!/usr/bin/env bats
# Render: picker rows (rows_build / --list) and the width-aware preview box
# (preview_render / --preview).

setup() {
  load test_helper
  jolt_setup
  use_ls mixed
  jolt_source
  NO_COLOR=1 theme_load
  config_load
}

# strip_ansi — stdin without SGR escape sequences.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# mk_session NAME TABS_KDL PANES_KDL — write a minimal cached metadata file.
mk_session() {
  mkdir -p "$JOLT_CACHE_DIR/$1"
  printf 'name "%s"\ntabs {\n%s\n}\npanes {\n%s\n}\n' "$1" "$2" "$3" \
    >"$JOLT_CACHE_DIR/$1/session-metadata.kdl"
}

# kdl_tab POS ACTIVE NAME / kdl_pane TAB TITLE [CMD] — block snippets.
kdl_tab() {
  printf '    tab {\n        position %s\n        name "%s"\n        active %s\n    }\n' "$1" "$3" "$2"
}
kdl_pane() {
  printf '    pane {\n        is_plugin false\n        is_suppressed false\n        title "%s"\n' "$2"
  [ -z "${3:-}" ] || printf '        terminal_command "%s"\n' "$3"
  printf '        tab_position %s\n    }\n' "$1"
}

# ── rows_build ──────────────────────────────────────────────────────────

@test "rows order and keys" {
  pins_toggle memora_new
  run rows_build
  assert_success
  assert_line --index 0 --regexp $'^a:new\t'
  assert_line --index 1 --regexp $'^a:project\t'
  assert_line --index 2 --regexp $'^a:layout\t'
  assert_line --index 3 --regexp $'^s:memora_new\t★ ○ memora_new'
  assert_line --index 6 --regexp $'^s:obsidian\t.*◆ obsidian.*\\(current\\)'
  [ "${#lines[@]}" -eq 7 ]
}

@test "rows action labels" {
  run rows_build
  assert_line --index 0 $'a:new\t+ new session'
  assert_line --index 1 $'a:project\t◇ project…'
  assert_line --index 2 $'a:layout\t▦ new from layout…'
}

@test "rows info column: tab counts, resurrect, current" {
  run rows_build
  assert_line --regexp $'^s:appr\t  ● appr .*  3 tabs$'
  assert_line --regexp $'^s:my proj \\(x\\)\t  ● my proj \\(x\\) .*  1 tab$'
  assert_line --regexp $'^s:memora_new\t  ○ memora_new .*  resurrect$'
  assert_line --regexp $'^s:obsidian\t  ◆ obsidian .*  \\(current\\)$'
}

@test "rows align: names padded to the longest name" {
  run rows_build
  # longest name is "my proj (x)" (11 cols): "  ● " + 11 + "  " + 4 + "  "
  assert_line $'s:appr\t  ● appr         now   3 tabs'
  assert_line $'s:my proj (x)\t  ● my proj (x)  now   1 tab'
}

@test "rows: active and exited sorted by last used, newest first" {
  mkdir -p "$JOLT_STATE_DIR"
  printf '%s\t%s\n' 1759990000 appr 1759999000 'my proj (x)' >"$JOLT_STATE_DIR/mru"
  run rows_build
  assert_line --index 3 --regexp $'^s:my proj \\(x\\)\t.* 16m '
  assert_line --index 4 --regexp $'^s:appr\t.* 2h '
  assert_line --index 5 --regexp $'^s:memora_new\t'
  assert_line --index 6 --regexp $'^s:obsidian\t'
}

@test "rows: pinned group sorted by last used; pinned current stays last" {
  mkdir -p "$JOLT_STATE_DIR"
  printf '%s\t%s\n' 1759990000 appr 1759999000 memora_new >"$JOLT_STATE_DIR/mru"
  printf '%s\n' appr memora_new obsidian >"$JOLT_STATE_DIR/pins"
  run rows_build
  assert_line --index 3 --regexp $'^s:memora_new\t★ ○ '
  assert_line --index 4 --regexp $'^s:appr\t★ ● '
  assert_line --index 5 --regexp $'^s:my proj \\(x\\)\t  ● '
  assert_line --index 6 --regexp $'^s:obsidian\t★ ◆ '
}

@test "rows hide exited when configured" {
  CFG_SHOW_EXITED=off
  run rows_build
  refute_line --partial 'memora_new'
  assert_line --regexp '^s:obsidian'
}

@test "rows: long names are truncated to 28 columns" {
  printf '%s\n' 'a-very-long-session-name-that-goes-on-forever [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run rows_build
  assert_line $'s:a-very-long-session-name-that-goes-on-forever\t  ● a-very-long-session-name-th…  ?     '
}

@test "rows: sessions without cache show no tab count" {
  printf '%s\n' 'nocache [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run rows_build
  assert_success
  assert_line --index 3 $'s:nocache\t  ● nocache  ?     '
}

@test "rows: no sessions → only the action rows" {
  export STUB_LS=""
  run rows_build
  assert_success
  [ "${#lines[@]}" -eq 3 ]
}

@test "rows colored glyphs when a theme is loaded" {
  theme_load
  run rows_build
  assert_line --regexp $'^s:appr\t.*\e\\[32m●'
}

@test "sessions_read skips names containing a TAB" {
  printf '%s\n' $'bad\tname [Created 1s ago] ' 'good [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run sessions_read
  assert_output $'good\tactive\t1s'
}

@test "sessions_read skips names containing control characters" {
  printf '%s\n' $'esc\e[31mname [Created 1s ago] ' $'bell\aname [Created 1s ago] ' 'good [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run sessions_read
  assert_output $'good\tactive\t1s'
}

# ── preview_render ──────────────────────────────────────────────────────

@test "preview box lines all same display width" {
  FZF_PREVIEW_COLUMNS=50 run preview_render "s:appr"
  assert_success
  [ "${#lines[@]}" -gt 5 ]
  while IFS= read -r l; do [ "$(dwidth "$l")" -eq 48 ] || { echo "bad: $l"; false; }; done <<<"$output"
}

@test "preview width holds for every fixture, narrow and colored" {
  theme_load
  local s cols l
  for s in appr memora_new obsidian jumping-tambourine 'my proj (x)' ghost a:new a:project a:layout; do
    for cols in 10 30 50 80; do
      [[ $s == a:* ]] && k=$s || k="s:$s"
      out=$(FZF_PREVIEW_COLUMNS=$cols preview_render "$k" | strip_ansi)
      while IFS= read -r l; do
        [ "$(dwidth "$l")" -eq $((cols - 2)) ] || { echo "bad ($s,$cols): $l"; false; }
      done <<<"$out"
    done
  done
}

@test "preview in a tiny pane is clamped to 8 columns" {
  local l
  for cols in 3 9; do
    out=$(FZF_PREVIEW_COLUMNS=$cols preview_render "s:appr" | strip_ansi)
    while IFS= read -r l; do
      [ "$(dwidth "$l")" -eq 8 ] || { echo "bad ($cols): $l"; false; }
    done <<<"$out"
  done
}

@test "preview default width is 60" {
  unset FZF_PREVIEW_COLUMNS
  run preview_render "s:appr"
  while IFS= read -r l; do [ "$(dwidth "$l")" -eq 58 ] || { echo "bad: $l"; false; }; done <<<"$output"
}

@test "preview tabs are 1-based, no plugin panes, no trailing comma" {
  run preview_render "s:appr"
  assert_output --partial "1. "
  refute_output --partial "0. "
  refute_output --partial "tab-bar"
  refute_output --regexp ',\s*│'
}

@test "preview session header and tab tree" {
  HOME=/home/ajay run preview_render "s:appr"
  assert_success
  assert_line --index 0 --regexp '^╭─ appr ─+╮$'
  assert_line --regexp '^│ status +● active +│$'
  assert_line --regexp '^│ created +1h 2m 3s ago +│$'
  assert_line --regexp '^│ last used +now +│$'
  assert_line --regexp '^│ cwd +~ +│$'
  refute_output --partial 'pinned'
  assert_line --regexp '^├─+┤$'
  assert_line --regexp '^│   1\. Tab #1 +│$'
  assert_line --regexp '^│ ▸ 3\. Tab #3 +│$'
  assert_line --regexp '^│     └ π: memora_issues +│$'
  assert_line --regexp '^╰─+╯$'
}

@test "preview: pinned row and cwd under HOME" {
  pins_toggle 'my proj (x)'
  HOME=/home/ajay run preview_render "s:my proj (x)"
  assert_line --regexp '^│ pinned +yes +│$'
  assert_line --regexp '^│ cwd +~/projects/my-proj +│$'
}

@test "preview: HOME prefix only replaced on a path boundary" {
  HOME=/home/aj run preview_render "s:my proj (x)"
  assert_line --regexp '^│ cwd +/home/ajay/projects/my-proj +│$'
}

@test "preview dedups panes and omits cmd equal to title" {
  printf '%s\n' 'jumping-tambourine [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  FZF_PREVIEW_COLUMNS=120 run preview_render "s:jumping-tambourine"
  assert_success
  assert_line --regexp '^│ ▸ 4\. Token Broker +│$'
  assert_line --regexp '^│     └ Bulk Datapulse — claude --dangerously-skip-permissions +│$'
  run grep -c 'ssh user@example.com' <<<"$output"
  assert_output 3
  refute_output --partial 'ssh user@example.com — '
}

@test "preview caps panes at 3 per tab with +N more" {
  mk_session many "$(kdl_tab 0 true work)" \
    "$(kdl_pane 0 one; kdl_pane 0 two cmd2; kdl_pane 0 three; kdl_pane 0 four; kdl_pane 0 five; kdl_pane 0 one)"
  printf '%s\n' 'many [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run preview_render "s:many"
  assert_line --regexp '^│     └ one +│$'
  assert_line --regexp '^│     └ two — cmd2 +│$'
  assert_line --regexp '^│     └ three +│$'
  assert_line --regexp '^│     └ \+2 more +│$'
  refute_output --partial 'four'
}

@test "preview: tabs ordered by position" {
  mk_session order "$(kdl_tab 1 false second; kdl_tab 0 true first)" ""
  printf '%s\n' 'order [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run preview_render "s:order"
  assert_line --index 5 --regexp '^│ ▸ 1\. first +│$'
  assert_line --index 6 --regexp '^│   2\. second +│$'
}

@test "preview: session without cache" {
  printf '%s\n' 'nocache [Created 1s ago] ' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run preview_render "s:nocache"
  assert_success
  assert_output --partial "no cached layout yet"
}

@test "preview: exited and current status" {
  run preview_render "s:memora_new"
  assert_line --regexp '^│ status +○ exited +│$'
  run preview_render "s:obsidian"
  assert_line --regexp '^│ status +◆ current +│$'
}

@test "preview action row" {
  run preview_render a:project
  assert_success
  assert_output --partial project
  assert_output --partial ctrl-o
  run preview_render a:layout
  assert_output --partial ctrl-l
  run preview_render a:new
  assert_output --partial "new session"
}

@test "preview missing session" {
  run preview_render s:ghost
  assert_success
  assert_output --partial "session not found"
}

# ── CLI ─────────────────────────────────────────────────────────────────

@test "--preview runs under zsh SHELL" {
  SHELL=/usr/bin/zsh run "$REPO/zellij-jolt.sh" --preview "s:appr"
  assert_success
  refute_output --partial "bad pattern"
  assert_output --partial "π: memora_issues"
}

@test "--preview needs a KEY" {
  run "$REPO/zellij-jolt.sh" --preview
  assert_failure 2
}

@test "--list prints the rows" {
  NO_COLOR=1 run "$REPO/zellij-jolt.sh" --list
  assert_success
  assert_line --index 0 $'a:new\t+ new session'
  assert_line --index 6 --regexp $'^s:obsidian\t'
}

@test "--list reuses exported theme instead of reloading it" {
  use_cfg legacy
  JOLT_THEME_DESC=x C_OK='<ok>' C_RESET='</>' run "$REPO/zellij-jolt.sh" --list
  assert_success
  assert_line --regexp $'^s:appr\t  <ok>●</> appr'
}

@test "--list honours SHOW_EXITED=off from the config file" {
  mkdir -p "$XDG_CONFIG_HOME/zellij-jolt"
  echo 'SHOW_EXITED=off' >"$XDG_CONFIG_HOME/zellij-jolt/config"
  NO_COLOR=1 run "$REPO/zellij-jolt.sh" --list
  assert_success
  refute_output --partial memora_new
}
