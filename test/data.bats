#!/usr/bin/env bats
# Data layer: list-sessions parsing, cached session metadata/layout parsing,
# MRU/pins state files and relative time formatting.

setup() {
  load test_helper
  jolt_setup
  jolt_source
}

# ── sessions_read ───────────────────────────────────────────────────────

@test "sessions_read parses all statuses and odd names" {
  use_ls mixed
  run sessions_read
  assert_success
  assert_line $'appr\tactive\t1h 2m 3s'
  assert_line $'obsidian\tcurrent\t2months 19days 5h 45m 17s'
  assert_line $'memora_new\texited\t2months 18days 6h 57m 32s'
  assert_line $'my proj (x)\tactive\t5m 1s'
  [ "${#lines[@]}" -eq 4 ]
}

@test "sessions_read empty is not an error" {
  run sessions_read
  assert_success
  assert_output ""
}

@test "sessions_read skips unparsable lines and names with brackets" {
  printf '%s\n' 'garbage line' 'a [b] c [Created 2s ago] (current)' '' >"$BATS_TEST_TMPDIR/ls.txt"
  export STUB_LS="$BATS_TEST_TMPDIR/ls.txt"
  run sessions_read
  assert_success
  assert_output $'a [b] c\tcurrent\t2s'
}

# ── meta_read ───────────────────────────────────────────────────────────

@test "meta_read tabs and filtered panes" {
  run meta_read appr
  assert_success
  assert_line --regexp $'^tab\t0\t(true|false)\t'
  assert_line $'tab\t0\tfalse\tTab #1'
  assert_line $'tab\t2\ttrue\tTab #3'
  assert_line --regexp $'^pane\t[0-9]+\tπ: memora_issues\t'
  assert_line $'pane\t2\tzsh in <ajay>\t'
  refute_line --partial 'zellij:tab-bar'
  refute_line --partial 'status-bar'
  refute_line --partial 'zellij:link'
}

@test "meta_read only reads tab/pane fields at block depth" {
  run meta_read appr
  # top-level `name "appr"` and history blocks must not leak in
  refute_line --partial $'\tappr'
  run bash -c 'grep -c "^tab	" <<<"$1"' _ "$output"
  assert_output 3
}

@test "meta_read pane commands and duplicate titles" {
  run meta_read jumping-tambourine
  assert_success
  assert_line --regexp $'^pane\t[0-9]+\tssh user@example.com\tssh user@example.com$'
}

@test "meta_read handles names with spaces and metadata-only sessions" {
  run meta_read "my proj (x)"
  assert_success
  assert_output $'tab\t0\ttrue\tmain\npane\t0\tzsh in <my proj (x)>\t'
  run meta_read test_web
  assert_success
}

@test "meta_read unescapes quotes and keeps output one line per record" {
  mkdir -p "$JOLT_CACHE_DIR/esc"
  cat >"$JOLT_CACHE_DIR/esc/session-metadata.kdl" <<'EOF'
name "esc"
tabs {
    tab {
        position 0
        name "say \"hi\" \\ there"
        active true
    }
}
panes {
    pane {
        id 1
        is_plugin false
        is_suppressed true
        title "hidden"
        tab_position 0
    }
    pane {
        title "a\tb"
        terminal_command "vim \"x y\""
        is_plugin false
        is_suppressed false
        tab_position 0
    }
}
EOF
  run meta_read esc
  assert_success
  assert_output $'tab\t0\ttrue\tsay "hi" \\ there\npane\t0\ta b\tvim "x y"'
}

@test "meta_read missing" {
  run meta_read nope
  assert_failure
  assert_output ""
}

# ── layout_cwd ──────────────────────────────────────────────────────────

@test "layout_cwd reads the top-level cwd" {
  run layout_cwd "my proj (x)"
  assert_success
  assert_output /home/ajay/projects/my-proj
  run layout_cwd memora_new
  assert_output /home/ajay/nitro
}

@test "layout_cwd empty without a cached layout" {
  run layout_cwd test_web
  assert_output ""
  run layout_cwd nope
  assert_output ""
}

# ── state ───────────────────────────────────────────────────────────────

@test "state_file paths live under XDG_STATE_HOME" {
  run state_file mru
  assert_output "$XDG_STATE_HOME/zellij-jolt/mru"
  run state_file pins
  assert_output "$XDG_STATE_HOME/zellij-jolt/pins"
}

@test "state touch/mru/pins/rename" {
  state_touch a
  run state_mru a
  assert_output 1760000000
  pins_toggle a
  pins_has a
  state_rename a b
  pins_has b
  run pins_has a
  assert_failure
  run state_mru b
  assert_output 1760000000
  run state_mru a
  assert_output ""
  pins_toggle b
  run pins_has b
  assert_failure
}

@test "state_touch upserts one line per name, atomically" {
  state_touch "my proj (x)"
  JOLT_NOW=1760000500 state_touch "my proj (x)"
  state_touch other
  run cat "$XDG_STATE_HOME/zellij-jolt/mru"
  assert_line $'1760000500\tmy proj (x)'
  assert_line $'1760000000\tother'
  [ "${#lines[@]}" -eq 2 ]
  run ls -A "$XDG_STATE_HOME/zellij-jolt"
  assert_output $'mru'
}

@test "pins_has needs an exact match" {
  pins_toggle "ab"
  run pins_has a
  assert_failure
  run pins_has "a*"
  assert_failure
  pins_has ab
}

@test "state_forget removes from mru and pins" {
  state_touch x
  state_touch y
  pins_toggle x
  state_forget x
  run state_mru x
  assert_output ""
  run pins_has x
  assert_failure
  run state_mru y
  assert_output 1760000000
}

@test "state_rename onto an existing name keeps one entry" {
  state_touch old
  JOLT_NOW=1759999000 state_touch new
  state_rename old new
  run cat "$XDG_STATE_HOME/zellij-jolt/mru"
  assert_output $'1760000000\tnew'
}

@test "last_used: mru, then cache mtime, then 0" {
  state_touch appr
  run last_used appr
  assert_output 1760000000
  touch -d @1700000000 "$JOLT_CACHE_DIR/obsidian"
  run last_used obsidian
  assert_output 1700000000
  run last_used nope
  assert_output 0
}

# ── reltime ─────────────────────────────────────────────────────────────

@test "reltime" {
  run reltime $((JOLT_NOW - 300))
  assert_output 5m
  run reltime $((JOLT_NOW - 3 * 86400))
  assert_output 3d
}

@test "reltime buckets" {
  run reltime "$JOLT_NOW"
  assert_output now
  run reltime $((JOLT_NOW - 59))
  assert_output now
  run reltime $((JOLT_NOW - 3 * 3600))
  assert_output 3h
  run reltime $((JOLT_NOW - 28 * 86400))
  assert_output 4w
  run reltime $((JOLT_NOW - 95 * 86400))
  assert_output 3mo
  run reltime $((JOLT_NOW - 400 * 86400))
  assert_output 1y
  run reltime 0
  assert_output '?'
  run reltime ''
  assert_output '?'
  run reltime $((JOLT_NOW + 100))
  assert_output now
}
