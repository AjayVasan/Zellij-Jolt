#!/usr/bin/env bats
# Actions: the `go` exit door (attach/create/switch), delete/purge/rename/pin
# keybind handlers, --action dispatch and --doctor.

setup() {
  load test_helper
  jolt_setup
  use_ls mixed
  jolt_source
  NO_COLOR=1 theme_load
  config_load
  JOLT_DRY_RUN=1
  unset JOLT_ASSUME_YES JOLT_RENAME_TO
  # Prompts read this file instead of the real terminal under test; it
  # does not exist unless a test writes an answer into it.
  export JOLT_TTY="$BATS_TEST_TMPDIR/tty"
}

# stub_count PATTERN — number of logged zellij calls matching PATTERN.
stub_count() {
  grep -c -- "$1" "$STUB_LOG" || true
}

@test "zellij on PATH is the test stub" {
  run command -v zellij
  assert_output "$REPO/test/stubs/zellij"
}

# ── run_or_exec / session_exists ────────────────────────────────────────

@test "run_or_exec dry run prints quoted argv" {
  run run_or_exec zellij attach "a b"
  assert_success
  assert_output 'DRY: zellij attach a\ b'
}

@test "session_exists matches exact names only" {
  session_exists appr
  session_exists "my proj (x)"
  session_exists memora_new
  run session_exists app
  assert_failure
  run session_exists "my proj"
  assert_failure
}

@test "session_exists with no sessions" {
  use_ls empty
  run session_exists appr
  assert_failure
}

# ── go ──────────────────────────────────────────────────────────────────

@test "go existing outside zellij attaches" {
  run go appr
  assert_success
  assert_output "DRY: zellij attach appr"
}

@test "go exited session outside zellij attaches (resurrect)" {
  run go memora_new
  assert_output "DRY: zellij attach memora_new"
}

@test "go new outside zellij creates" {
  run go fresh
  assert_success
  assert_output "DRY: zellij attach -c fresh"
}

@test "go new with layout and cwd" {
  run go fresh "$BATS_TEST_TMPDIR" compact
  assert_success
  assert_line "DRY: cd $BATS_TEST_TMPDIR"
  assert_line "DRY: zellij -n compact -s fresh"
}

@test "go new with a missing cwd fails" {
  run go fresh "$BATS_TEST_TMPDIR/nope"
  assert_failure
  refute_output --partial "DRY: zellij"
}

@test "go existing ignores cwd and layout outside zellij" {
  run go appr "$BATS_TEST_TMPDIR" compact
  assert_output "DRY: zellij attach appr"
}

@test "go inside zellij switches" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian run go appr
  assert_success
  assert_output "DRY: zellij action switch-session -- appr"
}

@test "go inside zellij passes cwd, and layout only for new sessions" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian run go appr /tmp compact
  assert_output "DRY: zellij action switch-session --cwd /tmp -- appr"
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian run go fresh /tmp compact
  assert_output "DRY: zellij action switch-session --cwd /tmp --layout compact -- fresh"
}

@test "go to current is noop" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian run go obsidian
  assert_success
  assert_output --partial "already in obsidian"
  refute_output --partial DRY
}

@test "go records mru" {
  go appr >/dev/null
  run state_mru appr
  assert_output 1760000000
}

@test "go to current does not touch mru" {
  ZELLIJ=0 ZELLIJ_SESSION_NAME=obsidian go obsidian >/dev/null
  run state_mru obsidian
  assert_output ""
}

@test "name with spaces quoted" {
  run go "my proj (x)"
  assert_output 'DRY: zellij attach my\ proj\ \(x\)'
}

@test "go without a name fails" {
  run go ""
  assert_failure
  refute_output --partial DRY
}

# ── confirm ─────────────────────────────────────────────────────────────

@test "confirm: assume-yes and CONFIRM_DELETE=off skip the prompt" {
  JOLT_ASSUME_YES=1 confirm "x?"
  CFG_CONFIRM_DELETE=off confirm "x?"
}

@test "confirm: answers from the tty" {
  printf 'y\n' >"$JOLT_TTY"
  run confirm "x?"
  assert_success
  printf 'YES\n' >"$JOLT_TTY"
  run confirm "x?"
  assert_success
  printf 'n\n' >"$JOLT_TTY"
  run confirm "x?"
  assert_failure
  printf '\n' >"$JOLT_TTY"
  run confirm "x?"
  assert_failure
}

@test "confirm: no tty means no" {
  run confirm "x?"
  assert_failure
}

# ── delete / purge ──────────────────────────────────────────────────────

@test "delete exited" {
  JOLT_ASSUME_YES=1 run act_delete s:memora_new
  assert_success
  assert_output ""
  grep -q $'^delete-session\x1f-f\x1f--\x1fmemora_new\x1f$' "$STUB_LOG"
  [ "$(stub_count kill-session)" -eq 0 ]
}

@test "delete active kills then deletes" {
  JOLT_ASSUME_YES=1 run act_delete s:appr
  assert_success
  run grep -e kill-session -e delete-session "$STUB_LOG"
  assert_line --index 0 $'kill-session\x1f--\x1fappr\x1f'
  assert_line --index 1 $'delete-session\x1f-f\x1f--\x1fappr\x1f'
}

@test "delete forgets mru and pin" {
  state_touch appr
  pins_toggle appr
  JOLT_ASSUME_YES=1 act_delete s:appr
  run state_mru appr
  assert_output ""
  run pins_has appr
  assert_failure
}

@test "delete declined does nothing" {
  printf 'n\n' >"$JOLT_TTY"
  run act_delete s:appr
  [ "$(stub_count kill-session)" -eq 0 ]
  [ "$(stub_count delete-session)" -eq 0 ]
}

@test "delete without tty or assume-yes does nothing" {
  run act_delete s:memora_new
  [ "$(stub_count delete-session)" -eq 0 ]
}

@test "delete refuses current" {
  ZELLIJ_SESSION_NAME=obsidian JOLT_ASSUME_YES=1 run act_delete s:obsidian
  assert_failure
  assert_output --partial "current"
  [ "$(stub_count obsidian)" -eq 0 ]
}

@test "delete refuses the session listed as current" {
  JOLT_ASSUME_YES=1 run act_delete s:obsidian
  assert_failure
  [ "$(stub_count obsidian)" -eq 0 ]
}

@test "delete of a vanished session is treated as gone" {
  state_touch ghost
  JOLT_ASSUME_YES=1 run act_delete s:ghost
  assert_success
  [ "$(stub_count delete-session)" -eq 0 ]
  run state_mru ghost
  assert_output ""
}

@test "delete: listed session gone by kill/delete time (kill rc 1, delete rc 2) succeeds" {
  state_touch appr
  pins_toggle appr
  STUB_RC_KILL=1 STUB_RC_DELETE=2 JOLT_ASSUME_YES=1 run act_delete s:appr
  assert_success
  [ "$(stub_count kill-session)" -eq 1 ]
  [ "$(stub_count delete-session)" -eq 1 ]
  run state_mru appr
  assert_output ""
  run pins_has appr
  assert_failure
}

@test "delete: other kill/delete failures are reported" {
  STUB_RC_KILL=3 JOLT_ASSUME_YES=1 run act_delete s:appr
  assert_failure
  assert_output --partial "kill-session"
  [ "$(stub_count delete-session)" -eq 0 ]
  STUB_RC_DELETE=1 JOLT_ASSUME_YES=1 run act_delete s:memora_new
  assert_failure
  assert_output --partial "delete-session"
}

@test "stub: -- ends options so the next arg is the target" {
  STUB_RC_DELETE=2 run zellij delete-session -f -- appr
  assert_failure 2
  run zellij kill-session -- -nope
  assert_failure 1
  assert_output --partial '"-nope"'
}

@test "delete ignores action rows" {
  JOLT_ASSUME_YES=1 run act_delete a:new
  assert_success
  [ "$(stub_count delete-session)" -eq 0 ]
}

@test "purge deletes only exited" {
  JOLT_ASSUME_YES=1 run act_purge
  assert_success
  grep -q $'^delete-session\x1f-f\x1f--\x1fmemora_new\x1f$' "$STUB_LOG"
  [ "$(stub_count delete-session)" -eq 1 ]
  [ "$(stub_count kill-session)" -eq 0 ]
}

@test "purge declined does nothing" {
  printf 'n\n' >"$JOLT_TTY"
  run act_purge
  [ "$(stub_count delete-session)" -eq 0 ]
}

@test "purge with no exited sessions says so" {
  use_ls empty
  JOLT_ASSUME_YES=1 run act_purge
  assert_success
  assert_output --partial "no exited sessions"
  [ "$(stub_count delete-session)" -eq 0 ]
}

# ── rename / pin ────────────────────────────────────────────────────────

@test "rename active" {
  JOLT_RENAME_TO="new name" run act_rename s:appr
  assert_success
  assert_output ""
  grep -q $'^--session=appr\x1faction\x1frename-session\x1f--\x1fnew-name\x1f$' "$STUB_LOG"
}

@test "rename moves mru and pin" {
  state_touch appr
  pins_toggle appr
  JOLT_RENAME_TO="new name" act_rename s:appr
  run state_mru new-name
  assert_output 1760000000
  pins_has new-name
}

@test "rename exited refused" {
  JOLT_RENAME_TO=x run act_rename s:memora_new
  assert_failure
  assert_output --partial "running"
  [ "$(stub_count rename-session)" -eq 0 ]
}

@test "rename to an existing name refused" {
  JOLT_RENAME_TO=memora_new run act_rename s:appr
  assert_failure
  assert_output --partial "exists"
  [ "$(stub_count rename-session)" -eq 0 ]
}

@test "rename to an unusable name refused" {
  JOLT_RENAME_TO="///" run act_rename s:appr
  assert_failure
  [ "$(stub_count rename-session)" -eq 0 ]
}

@test "rename gives up after 3 unusable answers" {
  printf '///\n' >"$JOLT_TTY"
  run act_rename s:appr
  assert_failure
  assert_output --partial "too many"
  [ "$(grep -c "unusable session name" <<<"$output")" -eq 3 ]
  [ "$(stub_count rename-session)" -eq 0 ]
}

@test "rename reads the new name from the tty" {
  printf 'from tty\n' >"$JOLT_TTY"
  run act_rename s:appr
  assert_success
  grep -q $'rename-session\x1f--\x1ffrom-tty\x1f$' "$STUB_LOG"
}

@test "rename with an empty answer or no tty cancels" {
  printf '\n' >"$JOLT_TTY"
  run act_rename s:appr
  [ "$(stub_count rename-session)" -eq 0 ]
  rm -f "$JOLT_TTY"
  run act_rename s:appr
  [ "$(stub_count rename-session)" -eq 0 ]
}

@test "pin toggles" {
  act_pin s:appr
  pins_has appr
  act_pin s:appr
  run pins_has appr
  assert_failure
}

# ── CLI ─────────────────────────────────────────────────────────────────

@test "--action pin via the CLI" {
  run "$REPO/zellij-jolt.sh" --action pin s:appr
  assert_success
  assert_output ""
  pins_has appr
}

@test "--action delete via the CLI" {
  JOLT_ASSUME_YES=1 run "$REPO/zellij-jolt.sh" --action delete s:memora_new
  assert_success
  assert_output ""
  grep -q $'^delete-session\x1f-f\x1f--\x1fmemora_new\x1f$' "$STUB_LOG"
}

@test "--action rename via the CLI" {
  JOLT_RENAME_TO=renamed run "$REPO/zellij-jolt.sh" --action rename s:appr
  assert_success
  grep -q $'rename-session\x1f--\x1frenamed\x1f$' "$STUB_LOG"
}

@test "--action purge needs no key" {
  JOLT_ASSUME_YES=1 run "$REPO/zellij-jolt.sh" --action purge
  assert_success
  [ "$(stub_count delete-session)" -eq 1 ]
}

@test "--action unknown or missing key exits 2" {
  run "$REPO/zellij-jolt.sh" --action bogus s:appr
  assert_failure 2
  run "$REPO/zellij-jolt.sh" --action delete
  assert_failure 2
}

@test "doctor runs" {
  run "$REPO/zellij-jolt.sh" --doctor
  assert_line --regexp '^bash [0-9.]+ \(ok\)$'
  assert_line "zellij 0.45.1 (ok)"
  assert_line --regexp '^fzf '
  assert_line --regexp '^cache dir '
  assert_line --regexp '^theme '
  assert_line --regexp '^zoxide (found|missing)$'
  assert_line --regexp '^fd (found|missing)$'
  assert_line --regexp '^config '
  assert_line --regexp '^state '
}

@test "doctor survives missing tools" {
  local bin="$BATS_TEST_TMPDIR/bin" t
  mkdir -p "$bin"
  for t in bash dirname basename readlink locale stat mkdir mv rm cat; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  ln -s "$REPO/test/stubs/zellij" "$bin/zellij"
  PATH="$bin" run "$REPO/zellij-jolt.sh" --doctor
  assert_failure 1
  assert_line "fzf missing (need >= 0.38.0)"
  assert_line "zellij 0.45.1 (ok)"
  assert_line "zoxide missing"
  assert_line "fd missing"
  assert_line --regexp '^state '
}
