# zellij-launcher

A beautiful fzf-based Zellij session launcher for Alacritty.

Opens a fuzzy-searchable session picker when Alacritty launches, with a
preview pane showing session details (tabs, panes, ages).

## Features

- **Session picker** — fuzzy-search existing Zellij sessions with `fzf`
- **Session preview** — right pane shows tabs, pane commands, age, status
- **New session options** — auto-named (untracked) or manually named sessions
- **Zellij-style theme** — green/cyan/dark aesthetic matching Zellij's look
- **GNOME shortcut integration** — optional Ctrl+Enter / Ctrl+Shift+Enter
- **Minimal dependencies** — just `zellij`, `fzf`, and `alacritty`

## Demo

```
┌── Zellij Session Launcher ───────────────────────────────────┐
│ Ctrl-n: New Untracked | Ctrl-N: New Named | Esc: Cancel      │
├──────────────────────────────────────────────────────────────┤
│ memora                                    ┌──────────────────┤
│ obsidian                                  │ Session Details  │
│ appr                                      │──────────────────┤
│ chatty-zebra                              │ memora           │
│>── New Untracked ──                       │ Age: 2h 18m      │
│ ── New Named ──                           │ Status: ACTIVE ✓ │
│ ── Cancel ──                              │ Tabs: 4          │
│                                           │──────────────────┤
│                                           │ 0. rca           │
│                                           │ 1. clauder       │
│                                           │ 2. m prod        │
│                                           │ 3. Tab #6        │
│                                           │──────────────────┤
│                                           │ Panes:           │
│                                           │ rca: opencode,   │
│                                           │ clauder: claude  │
│                                           │ m prod: ssh ubu  │
│                                           └──────────────────┘
└──────────────────────────────────────────────────────────────┘
```

## Installation

```bash
git clone <repo-url> ~/tmp/zellij-launcher
cd ~/tmp/zellij-launcher
./install.sh
```

The installer will:

1. Copy the script to `~/.local/share/zellij-launcher/`
2. Symlink to `~/.local/bin/zellij-launcher`
3. Optionally register GNOME keyboard shortcuts
4. Show Alacritty config instructions

## Dependencies

- **zellij** — terminal multiplexer
- **fzf** — fuzzy finder (v0.48+ for `--border-label`)
- **alacritty** — GPU-accelerated terminal (optional, for direct launch)

### Arch Linux

```bash
sudo pacman -S zellij fzf alacritty
```

## Usage

### From Alacritty (recommended)

Add to `~/.config/alacritty/alacritty.toml`:

```toml
[terminal]
shell = "zellij-launcher"
```

Now every Alacritty window opens the session picker instead of a raw shell.
When you exit Zellij (or cancel the picker), the window closes.

### From command line

```bash
zellij-launcher
```

### Keyboard shortcuts

**Within the picker:**

| Key | Action |
|---|---|
| `Ctrl+n` | Jump to "New Untracked Session" |
| `Ctrl+N` | Jump to "New Named Session" |
| `Esc` / `Ctrl+c` | Cancel |
| `Enter` | Select highlighted option |
| `Ctrl-p` / `Ctrl-n` | Navigate up/down |
| Type | Fuzzy filter the list |

**GNOME shortcuts (optional, set up by installer):**

| Shortcut | Action |
|---|---|
| `Ctrl+Enter` | Open Alacritty + Zellij picker |
| `Ctrl+Shift+Enter` | Open another Alacritty + Zellij picker |

## Session Details Panel

The preview pane on the right shows:

- **Session name** and **age**
- **Status** (ACTIVE or EXITED with resurrect info)
- **Tab list** with positions
- **Pane commands** per tab (e.g., `nvim`, `claude`, `ssh`, `tail -f`)

This data is read from Zellij's cache at
`~/.cache/zellij/contract_version_1/session_info/<name>/`.

## Uninstall

```bash
rm -rf ~/.local/share/zellij-launcher
rm -f ~/.local/bin/zellij-launcher
```

Remove the Alacritty `shell` config line if you added it.

## License

MIT