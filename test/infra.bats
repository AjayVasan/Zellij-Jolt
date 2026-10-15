#!/usr/bin/env bats
# Smoke tests for the test infrastructure itself (stub, helper, fixtures).
# Does not call jolt_source: these tests only exercise the stub and
# fixtures, not the script's functions.

setup() {
  load test_helper
  jolt_setup
}

@test "stub logs and replays ls" {
  use_ls mixed
  run zellij list-sessions -n
  assert_success
  assert_line --partial "my proj (x) [Created"
  run zellij list-sessions -s
  assert_line "my proj (x)"
  grep -q 'list-sessions' "$STUB_LOG"
}

@test "stub empty ls fails like zellij" {
  run zellij list-sessions -n
  assert_failure 1
}

@test "stub delete missing exits 2" {
  use_ls mixed
  run zellij delete-session -f nope
  assert_failure 2
}
