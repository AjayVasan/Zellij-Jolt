#!/usr/bin/env bats
# Tests for claude-zellij.sh: pane-id bootstrap, resume on restore, flag
# pass-through, and picking a working claude over a broken stub. A fake
# claude (records its argv) stands in for the real one; HOME is isolated.

setup() {
  load test_helper

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/projects/p" "$HOME/.claude/sessions"
  unset XDG_DATA_HOME XDG_BIN_HOME CLAUDE_ZELLIJ_BIN CLAUDE_CONFIG_DIR CLAUDE_ZELLIJ_STATE
  export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"

  cat >"$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ARGV_LOG"
EOF
  chmod +x "$HOME/.local/bin/claude"

  WRAP="$BATS_TEST_TMPDIR/claude-zellij"
  cp "$REPO/claude-zellij.sh" "$WRAP"
  chmod +x "$WRAP"
  STATE="$HOME/.local/share/claude-zellij"
  PID=11111111-2222-4333-8444-555555555555
  export ZELLIJ=0
}

@test "first run in a pane adds a pane id and starts a fixed conversation" {
  run "$WRAP" --model opus
  assert_success
  run cat "$ARGV_LOG"
  assert_output --regexp '^--session-id [0-9a-f-]{36} --model opus$'
  sid=${output#--session-id }
  sid=${sid%% *}
  run cat "$STATE"/*
  assert_output "$sid"
}

@test "never adds permission flags of its own" {
  run "$WRAP"
  assert_success
  run cat "$ARGV_LOG"
  refute_output --partial dangerously
}

@test "restore resumes the pane's recorded conversation" {
  mkdir -p "$STATE"
  CONV=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  echo "$CONV" >"$STATE/$PID"
  touch "$HOME/.claude/projects/p/$CONV.jsonl"
  run "$WRAP" --pane-id "$PID" --model opus
  assert_success
  run cat "$ARGV_LOG"
  assert_output "--resume $CONV --model opus"
}

@test "restore of a pane started with --resume ID resumes the recorded one" {
  mkdir -p "$STATE"
  OLD=aaaaaaaa-bbbb-4ccc-8ddd-000000000001
  NEW=aaaaaaaa-bbbb-4ccc-8ddd-000000000002
  touch "$HOME/.claude/projects/p/$OLD.jsonl" "$HOME/.claude/projects/p/$NEW.jsonl"
  echo "$NEW" >"$STATE/$PID"
  run "$WRAP" --pane-id "$PID" --resume "$OLD"
  assert_success
  run cat "$ARGV_LOG"
  assert_output "--resume $NEW"
}

@test "--resume ID in a new pane is wrapped and recorded" {
  OLD=aaaaaaaa-bbbb-4ccc-8ddd-000000000001
  touch "$HOME/.claude/projects/p/$OLD.jsonl"
  run "$WRAP" --resume "$OLD"
  assert_success
  run cat "$ARGV_LOG"
  assert_output "--resume $OLD"
  run cat "$STATE"/*
  assert_output "$OLD"
}

@test "a recorded conversation that no longer exists starts a new one" {
  mkdir -p "$STATE"
  echo aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee >"$STATE/$PID"
  run "$WRAP" --pane-id "$PID"
  assert_success
  run cat "$ARGV_LOG"
  assert_output --regexp '^--session-id [0-9a-f-]{36}$'
  refute_output --partial eeeeeeeeeeee
}

@test "--continue passes through and is not given a session id" {
  run "$WRAP" --continue
  assert_success
  run cat "$ARGV_LOG"
  assert_output "--continue"
}

@test "print mode, subcommands and --version go straight to claude" {
  run "$WRAP" -p hi
  run "$WRAP" mcp list
  run "$WRAP" --version
  run cat "$ARGV_LOG"
  assert_output $'-p hi\nmcp list\n--version'
}

@test "outside zellij it is plain claude" {
  unset ZELLIJ
  run "$WRAP" --model opus
  assert_success
  run cat "$ARGV_LOG"
  assert_output "--model opus"
  [ ! -d "$STATE" ] || [ -z "$(ls -A "$STATE")" ]
}

@test "skips a non-executable claude stub earlier in PATH" {
  rm "$HOME/.local/bin/claude"
  mkdir -p "$BATS_TEST_TMPDIR/broken" "$BATS_TEST_TMPDIR/good"
  echo 'echo stub' >"$BATS_TEST_TMPDIR/broken/claude"
  printf '#!/usr/bin/env bash\nprintf "good %%s\\n" "$*" >>"$ARGV_LOG"\n' >"$BATS_TEST_TMPDIR/good/claude"
  chmod +x "$BATS_TEST_TMPDIR/good/claude"
  PATH="$BATS_TEST_TMPDIR/broken:$BATS_TEST_TMPDIR/good:$PATH" run "$WRAP" -p x
  assert_success
  run cat "$ARGV_LOG"
  assert_output "good -p x"
}

@test "no executable claude is a clear error" {
  rm "$HOME/.local/bin/claude"
  PATH=/usr/bin:/bin run "$WRAP"
  assert_failure
  assert_output --partial "cannot find an executable 'claude'"
}

@test "a malformed pane id is refused" {
  run "$WRAP" --pane-id ../../etc
  assert_failure
  assert_output --partial "bad --pane-id"
}
