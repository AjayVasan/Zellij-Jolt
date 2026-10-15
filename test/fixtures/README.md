# Test fixtures

`session_info/` is copied (read-only, verbatim) from a real
`~/.cache/zellij/contract_version_1/session_info/` directory, except where
noted. Nothing in this tree is ever written back to that cache; `jolt_setup`
copies these fixtures *into* `$JOLT_CACHE_DIR` for each test.

| fixture dir | why it's here |
| --- | --- |
| `appr` | real session; pane title contains unicode `π` (`π: memora_issues`); also the literal name referenced as `s:appr` by later tasks |
| `memora_new` | real session; pane titles contain unicode `✳` (e.g. `✳ Analyze issue #398 and propose solutions`); used as the "exited" row in `ls/mixed.txt` |
| `obsidian` | real session; plain ASCII titles; used as the "current" row in `ls/mixed.txt` |
| `jumping-tambourine` | real session with duplicate `ssh user@example.com` pane titles (3 separate panes). Sanitized: the original title/`terminal_command` was `ssh ajayvasan@148.113.49.174` (a real IP + username) and was replaced with `ssh user@example.com` throughout both `.kdl` files |
| `test_web` | real session with only `session-metadata.kdl` (no `session-layout.kdl` — i.e. no cached layout) |
| `my proj (x)` | hand-written minimal fixture; name contains a space and parens to exercise name parsing/sanitization edge cases |

Unicode fixture name for later tasks to grep for: **`appr`** has pane title
`π: memora_issues`; **`memora_new`** has pane titles starting `✳ `.

`ls/mixed.txt` and `ls/empty.txt` are canned `zellij list-sessions -n` output
for the `test/stubs/zellij` stub (see `use_ls` in `test_helper.bash`).

`config/*.kdl` and `themes/mytheme.kdl` are zellij config fixtures covering
the theme formats described in the design spec's Testing section (no theme,
legacy inline palette, hex palette, 0.42+ component format, and
`theme_dir`-based external theme file). All of them describe the same
palette: fg `244 244 244` (`#f4f4f4`), bg `24 24 24` (`#181818`) — taken
verbatim from the user's real `~/.config/zellij/config.kdl` `gruber-darker`
theme block for `legacy.kdl`.
