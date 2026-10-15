# Zellij-Jolt

**A fast, keyboard-first fuzzy picker for Zellij sessions.**

Zellij-Jolt replaces your terminal's shell with an `fzf`-powered picker: fuzzy-find and attach to any session, jump straight into a project directory, spin up a session from a layout, rename/pin/delete, and resurrect exited sessions — all from one screen, with a live preview of what's actually running in each session. It reads Zellij's own on-disk session cache and never touches a session except through the actions you trigger.

```
  + new session
  ◇ project…
  ▦ new from layout…
★ ● api-server      2h   3 tabs        ╭─ api-server ───────────────╮
  ● scratch        12m   1 tab         │ status      ● active       │
  ◆ notes           5m   (current)     │ created     2h ago         │
  ○ old-demo         3d  resurrect     │ last used   2h ago         │
                                        │ pinned      yes            │
                                        │ cwd         ~/code/api     │
                                        ├─────────────────────────────┤
                                        │▸ 1. server                 │
                                        │    nvim src/main.rs        │
                                        │    cargo watch -x run      │
                                        │  2. logs                   │
                                        ╰─────────────────────────────╯
> _
```

`★` pinned · `●` active · `○` exited (resurrect) · `◆` current session.

## Features

- Unified picker — actions, pinned/active/exited sessions, and the current session all in one fuzzy list, ordered pinned → active → exited → current.
- Live preview — tabs (▸ marks the active one), deduped panes with their running command, created/last-used time, cwd, pin state.
- Project sessions — pick a project directory from `zoxide`, or a scan for git repositories under configured roots (`fd`/`find`), and jump straight into a session for it.
- Layout sessions — start a new session from any `*.kdl` layout, including Zellij's built-ins.
- Session actions from the picker: delete/kill, purge all exited, rename, pin/unpin.
- MRU + pins persisted across restarts; typed names that don't match anything create a new session.
- In-session switching — run it from inside Zellij and it uses `switch-session` instead of nesting.
- Renders in your Zellij theme's colors automatically (or no color at all under `NO_COLOR`).
- Guarded auto-start snippet for bash/zsh/fish, so a new terminal window drops you straight into the picker.
- `--doctor` for environment diagnostics; `--dry-run` to see the exact command without running it.

## Requirements

- `bash` ≥ 4.2 (macOS ships 3.2 — `brew install bash`, no need to change your login shell)
- `fzf` ≥ 0.38
- `zellij` ≥ 0.39 (≥ 0.44 to switch sessions from inside Zellij)
- Optional: `zoxide` (project picker), `fd` (project picker, faster directory scan)

## Install

```bash
git clone https://github.com/AjayVasan/Zellij-Jolt
cd Zellij-Jolt
./install.sh
```

This copies `zellij-jolt.sh` to `${XDG_DATA_HOME:-~/.local/share}/zellij-jolt/`, symlinks it at `${XDG_BIN_HOME:-~/.local/bin}/zellij-jolt`, checks dependency versions, and prints the config snippet for any terminal emulator it detects (see Setup below). On GNOME it also offers to register a keyboard shortcut (opt-in, skipped entirely under `--yes` or when stdin isn't a terminal; the shortcut opens zellij-jolt in the first terminal it finds — alacritty, kitty, wezterm, ghostty, foot or gnome-terminal — and is skipped when there is none).

```
Usage: install.sh [--yes] [--no-shortcut] [--uninstall] [--help]

  --yes           Non-interactive: accept every default, never prompt.
  --no-shortcut   Skip the GNOME keyboard-shortcut question entirely.
  --uninstall     Remove the installed script and symlink, then exit.
  --help          Show this help.

Stdin that isn't a terminal (e.g. piped input) behaves like --yes.
```

`./install.sh --uninstall` removes the symlink and install directory only — it never touches shell rc files, terminal config, or GNOME shortcuts.

Make sure `${XDG_BIN_HOME:-~/.local/bin}` is on your `PATH`.

## Setup

Pick one: make `zellij-jolt` your terminal's shell (so every new window opens the picker), or add the `--init-shell` snippet to your shell rc (so an interactive shell drops into the picker right after it starts). Either way, finish with the in-Zellij keybinding below so you can summon the picker without leaving a session.

**Alacritty** (`alacritty.toml`):
```toml
[terminal]
shell = "/home/you/.local/bin/zellij-jolt"
```

**Ghostty** (`config`):
```
command = /home/you/.local/bin/zellij-jolt
```

**Kitty** (`kitty.conf`):
```
shell /home/you/.local/bin/zellij-jolt
```

**WezTerm** (`wezterm.lua`):
```lua
config.default_prog = { "/home/you/.local/bin/zellij-jolt" }
```

**foot** (`foot.ini`):
```ini
[main]
shell=/home/you/.local/bin/zellij-jolt
```

**Shell rc alternative** — instead of replacing the terminal's shell, add a guarded auto-start line to your interactive shell's rc file:

```bash
zellij-jolt --init-shell zsh >> ~/.zshrc   # or bash / fish
```

This only fires outside Zellij/tmux, on a real tty, in an interactive shell, when `$TERM` isn't `dumb` or `vscode`, and when `JOLT_SKIP` isn't set — so it's safe to leave in your rc permanently.

**In-Zellij keybinding** — add to your Zellij `config.kdl` so `Alt s` opens the picker as a floating pane without leaving your session:

```kdl
keybinds {
    shared_except "locked" {
        bind "Alt s" { Run "zellij-jolt" { floating true; close_on_exit true; }; }
    }
}
```

## Keys

| Key | Action | Config override |
|---|---|---|
| `enter` | open the selected session / create the typed name | — |
| `alt-enter` | create a session named after the query | `KEY_CREATE` |
| `ctrl-d` | kill / delete the selected session | `KEY_DELETE` |
| `alt-d` | delete all exited sessions | `KEY_PURGE` |
| `ctrl-r` | rename the selected session | `KEY_RENAME` |
| `ctrl-t` | pin / unpin the selected session | `KEY_PIN` |
| `ctrl-o` | open a project directory as a session | `KEY_PROJECT` |
| `ctrl-l` | new session from a layout | `KEY_LAYOUT` |
| `ctrl-/` | toggle the preview | `KEY_PREVIEW` |
| `?` | key help in the preview | `KEY_HELP` |
| `esc` | back / quit | — |

Override values must be plain fzf key names (`ctrl-d`, `alt-enter`, `ctrl-/`, `?`, `f1`, …); anything else is rejected with a warning and falls back to the default.

## Configuration

File: `${XDG_CONFIG_HOME:-~/.config}/zellij-jolt/config`, plain `KEY=VALUE` lines (`#` comments, blank lines ignored). Only the keys below are recognized — unknown keys and malformed lines are warned about and skipped. Values are taken literally (no shell expansion, no sourcing/eval), except a leading `~` or `~/` is expanded to `$HOME`.

| Key | Default | Meaning |
|---|---|---|
| `PROJECT_ROOTS` | `~/projects ~/code ~/src ~/dev` | Space-separated parent directories scanned for git repositories by the project picker (`ctrl-o`), used when `zoxide` has no candidates |
| `PROJECT_DEPTH` | `3` | Max directory depth to search under each root when `fd`/`find` is used |
| `DEFAULT_LAYOUT` | *(empty)* | Layout name applied to new sessions created via the project picker |
| `PREVIEW` | `on` | `on`/`off` — show the preview pane |
| `PREVIEW_POS` | `right` | `right`/`left`/`top`/`bottom` — preview pane position (invalid values fall back to `right`) |
| `SHOW_EXITED` | `on` | `on`/`off` — list exited sessions (pinned ones always show) |
| `THEME` | `auto` | `auto` (read from Zellij config), `none` (no color), or a specific Zellij theme name |
| `CONFIRM_DELETE` | `on` | `on`/`off` — confirm before delete/kill/purge |
| `KEY_DELETE` | `ctrl-d` | Keybinding override, see Keys above |
| `KEY_PURGE` | `alt-d` | Keybinding override |
| `KEY_RENAME` | `ctrl-r` | Keybinding override |
| `KEY_PIN` | `ctrl-t` | Keybinding override |
| `KEY_PROJECT` | `ctrl-o` | Keybinding override |
| `KEY_LAYOUT` | `ctrl-l` | Keybinding override |
| `KEY_PREVIEW` | `ctrl-/` | Keybinding override |
| `KEY_HELP` | `?` | Keybinding override |
| `KEY_CREATE` | `alt-enter` | Keybinding override |

Example:

```
PROJECT_ROOTS=~/code ~/work
PROJECT_DEPTH=4
DEFAULT_LAYOUT=dev
PREVIEW_POS=bottom
SHOW_EXITED=off
THEME=none
KEY_DELETE=ctrl-x
```

## CLI reference

```
zellij-jolt                         picker (default)
zellij-jolt --list                  print picker rows (used by fzf reload)
zellij-jolt --preview KEY           render preview for a row key
zellij-jolt --action ACT KEY        keybind handler: delete|rename|pin|purge
zellij-jolt --dry-run               print final zellij command instead of exec
zellij-jolt --init-shell SHELL      print guarded auto-start snippet (bash|zsh|fish)
zellij-jolt --doctor                environment diagnostics
zellij-jolt --version | --help
zellij-jolt --preview-dir DIR       (internal) project preview listing
```

`--preview`, `--list`, `--action` and `--preview-dir` are internal callbacks used by fzf (preview, reload and keybind handlers); you won't normally run them by hand. `--dry-run` runs the picker but prints the `zellij`/`exec` command it would have run instead of executing it — useful for checking what a selection will actually do.

## Troubleshooting

- **Preview shows errors / garbled output under zsh** — fixed in v2 (the preview callback now re-invokes the script by absolute path instead of relying on `$SHELL`, which broke under zsh in v1).
- **`bash: command not found` or version errors on macOS** — macOS ships bash 3.2. Install a newer one with `brew install bash`; you don't need to change your login shell, Zellij-Jolt will use it directly.
- **Running it from inside a Zellij session** — Zellij-Jolt detects `$ZELLIJ` and uses `zellij action switch-session` instead of starting a nested session. Selecting the session you're already in is a no-op. `switch-session` needs zellij ≥ 0.44; on older versions Zellij-Jolt says so — detach first (Ctrl-o d) and run it outside.
- **Something looks wrong with versions, theme, or paths** — run `zellij-jolt --doctor`:
  ```
  bash 5.3.20 (ok)
  fzf 0.74.5 (ok)
  zellij 0.45.1 (ok)
  cache dir /home/you/.cache/zellij/contract_version_1/session_info
  theme gruber-darker (legacy palette)
  zoxide missing
  fd missing
  config /home/you/.config/zellij-jolt/config (not found, using defaults)
  state /home/you/.local/state/zellij-jolt
  ```
- **Don't want auto-start in a particular shell** — set `JOLT_SKIP=1` before that shell starts; the `--init-shell` snippet checks for it and no-ops.

## How it works

Zellij-Jolt reads Zellij's own session list (`zellij list-sessions`) and its on-disk session cache (`${XDG_CACHE_HOME:-~/.cache}/zellij/contract_version_*/session_info`) to build the picker and preview — it never creates, modifies, or deletes a session on its own. Every session mutation (delete, purge, rename, pin, attach, create) happens only in direct response to a key you press or a session you select.

## Uninstall

```bash
./install.sh --uninstall
```

Then remove any terminal config snippet or `--init-shell` line you added, and delete `${XDG_CONFIG_HOME:-~/.config}/zellij-jolt` and `${XDG_STATE_HOME:-~/.local/state}/zellij-jolt` if you want to drop your config/MRU/pins too.

## Roadmap

**M2 — Ship**: AUR (stable + `-git`), Homebrew tap, Nix package, curl installer, man page, shell completions, CI (Linux + macOS, shellcheck, shfmt), demo GIF, comparison table.

**M3 — Differentiators**: live `dump-screen` preview, SSH remote sessions, git worktree/branch sessions, AI-agent status column, session notes, doctor-reap of zombie sessions.

## License

MIT
