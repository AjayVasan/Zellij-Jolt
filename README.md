# Zellij-Jolt

**Jolt into your Zellij sessions — fuzzy picker, live preview, instant attach.**

A single `bash` script that replaces your terminal's raw shell with a fuzzy Zellij session picker. Opens an `fzf` TUI with four actions and a live preview pane on the right — tab names, what's running in each, age, status. Actions: create a named session, create an auto-named session, resume an existing session via a fuzzy sub-picker, or exit. Works as a drop-in Alacritty `shell` or via `-e` flag.

Reads Zellij's own on-disk cache — zero config. Renders in your exact Zellij theme colors (gruber-darker by default).

---

## How it works — the full picture

### Entry points

Alacritty launches `zellij-jolt` in one of two ways:

**A) `[terminal] shell = "zellij-jolt"`** — every new Alacritty window runs the picker instead of a login shell. When you exit Zellij (or escape the picker), Alacritty closes because its child process terminated.

**B) `alacritty -e zellij-jolt`** — used by GNOME keyboard shortcuts. Same effect; the `-e` flag tells Alacritty to run a command instead of the configured shell.

Either way, the script gets a TTY on stdin. Line 236 does `exec < /dev/tty` to guarantee fzf can interact with the terminal (covers edge cases where stdin might be inherited as a pipe).

### Dependency check (lines 222–224)

Before doing anything, verifies `zellij` and `fzf` are on `PATH`. Exits with an error message if either is missing — no silent failure into a blank screen.

### Session list (lines 226–234)

The main picker shows exactly four action entries — no session names are listed on the main page. Sessions appear only in the Resume sub-picker.

```
── New Named ──
── New Untracked ──
── Resume ──
── Exit ──
```

The `──` wrappers visually separate actions from real session names and prevent name collisions (no real Zellij session is named `── New Named ──`).

Selecting `── Resume ──` opens a sub-picker that lists all existing Zellij sessions with their creation time and status. The sub-picker supports fuzzy search — type to filter sessions instantly. A live preview on the right shows detailed session info: tab names, pane titles, age, and status.

### The fzf picker (lines 238–264)

fzf is invoked with these key settings:

| Flag | Purpose |
|---|---|
| `--ansi` | Interpret ANSI escape codes in preview output |
| `--layout=reverse` | Top-down list, most recent at top |
| `--border=sharp` | ASCII box-drawing (`──`, `│`, etc.) |
| `--preview-window=right:60%:border-sharp` | Right panel takes 60% width |
| `--bind=ctrl-n:become(...)` | Ctrl+n immediately selects "New Untracked"; Ctrl+N for "New Named" |
| `--color=...` | Exact gruber-darker palette (see Theme section below) |

The `become` action replaces fzf's own process — when you press Ctrl+n, fzf exits and echoes the special entry string back, which the `case` statement on line 266 catches.

#### Preview: how it communicates with fzf (lines 254–263)

This is the trickiest part. fzf's `--preview` runs a shell command for every highlighted line, substituting `{}` with the current item. We need that command to call our `session_preview` function — but the preview runs in a separate process that doesn't inherit bash function definitions.

The solution: `$(declare -f session_preview parse_metadata_file _box_top ...)` inline-expands the function source code into the preview command string at script-evaluation time. So fzf receives a fully self-contained bash script:

```bash
item=memora;
session_preview() {
    ... entire function body inlined ...
}
parse_metadata_file() {
    ... entire function body inlined ...
}
_box_top() { ... }
...
session_preview "$item"
```

The `item={}` line lets fzf substitute the current entry into `$item`. Every function the preview needs must be listed in `declare -f` — missing one means a "command not found" error in the preview pane.

`ZELLIJ_SESSION_DIR` is exported (line 11) so the preview subshell can read it.

### Session metadata parser (lines 46–103)

Zellij serializes session state to `~/.cache/zellij/contract_version_1/session_info/<name>/session-metadata.kdl`. A partial KDL state machine parser in pure bash reads it:

```
tabs {
    tab { position 0  name "rca"   ... }
    tab { position 1  name "clauder" ... }
}
panes {
    pane { id 4  is_plugin false  title "✳ Claude Code"  tab_position 1 ... }
    pane { id 7  is_plugin true   title "zellij:tab-bar"                ... }
}
```

The parser tracks a two-level state machine:

| State | Entry | Content handled |
|---|---|---|
| `section=""` | looks for `tabs {` or `panes {` | transitions to section |
| `section="tabs"` | `tab {` / `}` | extracts `position`, `name` |
| `section="panes"` | `pane {` / `}` | extracts `title`, `is_plugin`, `tab_position` |

Output is pipe-separated lines consumed by the preview renderer:

```
tab|0|rca
tab|1|clauder
tab|2|m prod
tab|3|Tab #6
pane|1|✳ Claude Code
pane|2|ssh ubuntu@memora.nitrocommerce.io
```

Only non-plugin panes (`is_plugin false`) are emitted — no tab-bar or status-bar noise. Exited sessions with no cache show "no cached data" gracefully.

### Action dispatch (lines 266–286)

The `case` statement maps fzf's output to a Zellij command:

| fzf output | Action |
|---|---|
| `── New Named ──` | prompts for name → `exec zellij -s "$name"` |
| `── New Untracked ──` | `exec zellij` — creates a random animal-name session |
| `── Resume ──` | opens a sub-picker with fuzzy search → `exec zellij attach <session>` |
| `── Exit ──` or empty | `exit 0` — closes the terminal |

`exec` replaces the script process with zellij — no zombie processes, clean process tree.

---

## Theme system

### Source: Zellij config

The launcher reads its color palette from `~/.config/zellij/config.kdl`:

```kdl
themes {
    gruber-darker {
        fg 244 244 244
        bg 24 24 24
        red 244 56 65
        green 115 217 54
        yellow 255 221 126
        blue 150 166 200
        magenta 158 149 199
        orange 255 79 90
        cyan 149 169 159
        black 0 0 0
        white 228 228 228
    }
}
theme "gruber-darker"
```

### Applied in two layers

**1. fzf chrome** — `FZF_COLORS` (lines 28–39) maps theme colors to fzf's UI slots via hex codes:

| Theme color | fzf role | Hex |
|---|---|---|
| `bg 24 24 24` | list background, gutter | `#181818` |
| — | selected line bg | `#242424` |
| `fg 244 244 244` | title text, labels, tab names | `#f4f4f4` |
| `white 228 228 228` | fzf default fg, preview fg | `#e4e4e4` |
| `green 115 217 54` | border, pointer, highlight, marker | `#73d936` |
| `cyan 149 169 159` | info line, prompt | `#95a99f` |
| `yellow 255 221 126` | spinner | `#ffdd7e` |
| — | header text | `#505050` |
| — | preview bg | `#101010` |

**2. Preview pane** — 24-bit ANSI escape sequences (lines 17–27) use `$'...'` syntax to embed the actual ESC byte at variable definition time, not at print time:

```bash
C_BD=$'\e[38;2;115;217;54m'   # green borders
C_TL=$'\e[1;38;2;244;244;244m' # bold white title
C_VL=$'\e[38;2;255;221;126m'   # yellow values (age)
C_ST=$'\e[38;2;149;169;159m'   # cyan tab position numbers
```

Each `\e` becomes ASCII byte 0x1B in the variable value, so `printf "$C_BD"` writes the escape sequence directly — no format-string interpretation needed. This also survives subshells and fzf's `declare -f` inlining.

### Render helpers (lines 106–113)

Six `_box_*` functions abstract the preview box-drawing:

```
_box_top     → ╭──────────────────────────────────────────────╮
_box_sep     → ├──────────────────────────────────────────────┤
_box_bot     → ╰──────────────────────────────────────────────╯
_box_title   → │ session_name                                 │
_box_label   → │ Age:    2h 25m                               │
_box_tab     → │  0.  rca                                    │
_box_pane    → │       └ OC | False split rate root cause    │
_box_line    → │  Some text                                  │
```

Each wraps content between green box borders (`C_BD`), applies the correct content color (`C_TL`, `C_VL`, etc.), then resets with `C_RESET`. Width is fixed at 46 visible characters — content is truncated with `${var:0:N}` to prevent overflow.

### Switching themes

To use a different Zellij theme, update the 11 color variables at the top of the script. The Zellij theme name is a convention — you could also read the KDL config at runtime (but the script keeps it hardcoded for speed and simplicity).

---

## Installation walkthrough

### What `install.sh` does

1. **Copies the script** to `~/.local/share/zellij-jolt/zellij-jolt.sh`
2. **Symlinks** to `~/.local/bin/zellij-jolt` (make sure `~/.local/bin` is on your PATH)
3. **Checks dependencies** — `zellij`, `fzf`, `alacritty`. Shows Arch pacman commands for any missing. Optionally continues anyway.
4. **Offers GNOME shortcut registration** — only runs if `$XDG_CURRENT_DESKTOP == "GNOME"`. Uses `gsettings` to add custom keybindings:
   - `custom<N>: <Control>Return → alacritty -e zellij-jolt`
   - `custom<N>: <Control><Shift>Return → alacritty -e zellij-jolt`
   
   The `gsettings_set_shortcut` function (lines 26–69) scans existing custom slots, reuses one if the same binding already exists (updates its command), or appends a new slot. This avoids accumulating dead shortcut entries on reinstall.

5. **Prints Alacritty config instructions** for the `shell` method.

### Manual install

```bash
cp zellij-jolt.sh ~/.local/bin/zellij-jolt
chmod +x ~/.local/bin/zellij-jolt
```

### Uninstall

```bash
rm ~/.local/bin/zellij-jolt
rm -rf ~/.local/share/zellij-jolt
```

Remove Alacritty `[terminal] shell` line if you added one, and delete the GNOME shortcuts from Settings → Keyboard → Shortcuts.

---

## File structure

```
zellij-jolt.sh     # The entire launcher — self-contained
install.sh          # Installer with dep checking + GNOME shortcut setup
README.md           # This file
.gitignore
```

No config files, no plugins, no wasm, no dependencies beyond `zellij` and `fzf`.

---

## Dependencies

| Tool | Required? | Version notes |
|---|---|---|
| `zellij` | yes | 0.40+ for `list-sessions -s` (short format). Tested on 0.44.3 |
| `fzf` | yes | 0.48+ for `--border-label` and `become` action. Tested on 0.74.1 |
| `alacritty` | no (for shortcuts) | Any version. Works with any terminal that supports `-e` or `shell` config |
| `bash` | yes | Uses `$'...'`, `declare -f`, `exec < /dev/tty`. Bash 4+ |

---

## Picker key bindings

| Key | Action |
|---|---|
| `Ctrl+n` | Jump to "New Untracked" |
| `Ctrl+N` (shift) | Jump to "New Named" (prompt for name) |
| `Enter` | Attach/create selected session |
| `Esc` / `Ctrl+c` | Cancel, exit |
| `Ctrl+j` / `Ctrl+k` | Move down/up |
| Any text | Fuzzy filter the session list |

The `become` bindings (Ctrl+n / Ctrl+N) make fzf exit immediately and echo the special option string — faster than manually scrolling to the bottom of the list.

---

## How the preview data flows

```
zellij list-sessions -n
  → "memora [Created 2h 25m ago]"
    → parse age from [...], detect ACTIVE/EXITED from (...) 

~/.cache/.../session-metadata.kdl
  → parse_metadata_file() — state machine KDL parser
    → tab|0|rca
      pane|1|✳ Claude Code
      ...
        → session_preview() collects into arrays
          → _box_* functions render with theme colors
            → output to fzf --preview on highlighted line
```

---

## Edge cases handled

| Scenario | Behavior |
|---|---|
| No Zellij sessions | List shows 4 action options; Resume shows "No sessions" |
| Session cache missing | Preview shows "(no cached data)" with basic info |
| Session deleted between list render and attach | `zellij attach` fails, falls through to `zellij -s` (recreates) |
| Terminal with no TTY | `exec < /dev/tty` reopens the controlling terminal |
| `zellij` or `fzf` not installed | Script exits immediately with error |
| Very long session names | Truncated with `${var:0:44}` in preview |
| Many tabs in session | All displayed; fzf preview scrolls if needed |

---

## License

MIT