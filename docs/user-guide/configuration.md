# Configuration

Mistty reads a single [TOML](https://toml.io/) file:

```
~/.config/mistty/config.toml
```

The file is optional — every key has a built-in default. Set only what you want to change. A fully-commented sample with every option at its default lives at [`docs/config-example.toml`](../config-example.toml); copy it as a starting point:

```sh
mkdir -p ~/.config/mistty
cp docs/config-example.toml ~/.config/mistty/config.toml
```

This page is the reference; the sample file is the quickest way to see everything in context.

## Reloading

Changes apply when the config is reloaded. Bind a chord to the `reload_config` action (it has no default — see [Shortcuts](#shortcuts)), run `mistty-cli config reload`, or edit the config from Mistty's Settings window. If the file has a syntax error or a shortcut conflict, the reload is rejected and the previous good config stays in effect.

Some settings are passed straight through from Mistty to the Ghostty rendering layer. To see those settings, run `mistty-cli config show`.

## Top-level options

| Key                 | Type   | Default             | Description                                                                                                                                                                                         |
| ------------------- | ------ | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `font_size`         | int    | `13`                | Terminal font size, in points (Ghostty `font-size`).                                                                                                                                                |
| `font_family`       | string | _(Ghostty default)_ | Monospace font family (Ghostty `font-family`). Leave unset to keep Ghostty's own font list.                                                                                                         |
| `cursor_style`      | string | `"block"`           | Cursor shape: `block`, `bar`, or `underline` (Ghostty `cursor-style`).                                                                                                                              |
| `scrollback_lines`  | int    | `10000`             | Scrollback buffer size in lines (Ghostty `scrollback-limit`).                                                                                                                                       |
| `sidebar_visible`   | bool   | `true`              | Show the sidebar on launch. Toggle at runtime with `Cmd+S`.                                                                                                                                         |
| `scroll_multiplier` | float  | `2.0`               | Multiplier for trackpad / Magic Mouse precision scroll deltas. `1.0` = raw macOS deltas (usually too fast). Mouse-wheel scrolling is unaffected — use `[ghostty] mouse-scroll-multiplier` for that. |
| `zoxide_path`       | string | _(auto-detected)_   | Absolute path to the `zoxide` binary. Skips Mistty's probe of common install locations. Leading `~` is expanded.                                                                                    |
| `debug_logging`     | bool   | `false`             | Write diagnostic logs to `~/Library/Logs/Mistty/mistty-debug.log`. For troubleshooting only — small per-write overhead.                                                                             |

## `[ssh]`

Controls how the [session manager](getting-started.md#the-session-manager) opens SSH hosts.

| Key               | Type   | Default | Description                                                          |
| ----------------- | ------ | ------- | -------------------------------------------------------------------- |
| `default_command` | string | `"ssh"` | Command used to connect. The host is appended as the final argument. |

Add per-host overrides with `[[ssh.host]]` blocks. Match by exact `hostname` or by `regex`; the first match wins. Useful if you want to use an alternative command to connect, e.g. `mosh` or `et`

```toml
[ssh]
default_command = "ssh"

[[ssh.host]]
hostname = "prod.example.com"
command = "mosh"

[[ssh.host]]
regex = "^.*\\.staging\\.example\\.com$"
command = "et"
```

## `[copy_mode]`

See [Copy mode](copy-mode.md) for what these affect.

| Key         | Type | Default | Description                                                                                                                               |
| ----------- | ---- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `scrolloff` | int  | `0`     | Minimum rows kept visible above/below the cursor during `j`/`k` motions (vim's `scrolloff`). `0` lets the cursor reach the viewport edge. |

### `[copy_mode.hints]`

| Key                | Type   | Default       | Description                                                                                                                                                                                                       |
| ------------------ | ------ | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `alphabet`         | string | `"asdfghjkl"` | Letters used for hint labels, assigned in order. Avoid `1`/`2`/`3` — those switch the active action while hints are open.                                                                                         |
| `uppercase_action` | string | `"open"`      | What uppercase hint letters do; lowercase does the other. `open` = uppercase opens / lowercase copies; `copy` = the reverse; `cursor` = uppercase jumps the copy-mode cursor to the label and stays in copy mode. |

## `[notifications]`

Mistty raises a macOS notification when a program in a pane emits an OSC 9 or OSC 777 escape sequence (e.g. "build finished"). A notification from a pane you're not looking at also flags its tab and the Dock icon.

| Key       | Type | Default | Description                                                                                                                                                           |
| --------- | ---- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enabled` | bool | `true`  | Master switch. Setting it explicitly to `true` makes Mistty request notification permission at launch (rather than the first time one fires). Set `false` to disable. |

## `[ui]`

Window chrome and pane appearance.

| Key                       | Type                | Default                | Description                                                                                                                                                                        |
| ------------------------- | ------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tab_bar_mode`            | string              | `"when_multiple_tabs"` | When to show the tab bar: `always`, `never`, `when_sidebar_hidden`, `when_sidebar_hidden_and_multiple_tabs`, or `when_multiple_tabs`.                                              |
| `title_bar_style`         | string              | `"hidden_with_lights"` | `always` (standard title bar), `hidden_with_lights` (hidden, traffic lights float over content), or `hidden_no_lights` (hidden, no traffic lights — close with `Cmd+W` / `Cmd+Q`). |
| `content_padding_x`       | int or `[int, int]` | _(none)_               | Horizontal padding inside the terminal surface, in points. A single value is symmetric; `[left, right]` splits. Maps to Ghostty `window-padding-x`.                                |
| `content_padding_y`       | int or `[int, int]` | _(none)_               | Vertical padding (`[top, bottom]`). Maps to Ghostty `window-padding-y`.                                                                                                            |
| `content_padding_balance` | bool                | _(none)_               | Distribute leftover pixels as extra padding to keep the grid centered. Maps to Ghostty `window-padding-balance`.                                                                   |
| `pane_border_color`       | string              | _(system separator)_   | Border color between split panes: `"#rrggbb"` or `"#rrggbbaa"`. Omit to use the system separator color.                                                                            |
| `pane_border_width`       | int                 | `1`                    | Border thickness between panes, in points.                                                                                                                                         |

The tab bar can also be toggled per-window with `Cmd+Shift+B`, independent of `tab_bar_mode`.

## `[shortcuts]`

Rebind any global or menu-bar shortcut. The default for every action is listed in [Keyboard shortcuts](keyboard-shortcuts.md); set an action here to override it.

```toml
[shortcuts]
new_tab        = "cmd+t"
session_manager = "cmd+j"
reload_config  = "cmd+shift+,"   # bind an action that has no default
toggle_sidebar = ""              # disable a default binding
next_tab       = ["cmd+]", "cmd+down"]   # bind multiple chords
# next_tab       = "cmd+]" # not allowed: each action can only be listed once
# missing actions keep their default
```

**Chord grammar:** `<modifier>+...+<key>`

- **Modifiers:** `cmd`, `shift`, `opt` (alias `alt`), `ctrl` (alias `control`). Order doesn't matter; case-insensitive; `+` and `-` both work as separators.
- **Keys:** any single character (`a`, `]`, `1`, `/`), or a named key (case-insensitive): `up`, `down`, `left`, `right`, `escape`, `return`, `tab`, `space`, `backspace`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`.

### Indexed shortcuts

`Cmd+1`…`Cmd+9` focus tabs and `Ctrl+1`…`Ctrl+9` focus sessions. You can change the modifier (not individual digits):

| Key                      | Default  | Description                                                      |
| ------------------------ | -------- | ---------------------------------------------------------------- |
| `focus_tab_modifier`     | `"cmd"`  | Modifier for focus-tab-N.                                        |
| `focus_session_modifier` | `"ctrl"` | Modifier for focus-session-N. Must differ from the tab modifier. |

## `[ghostty]` — passthrough

Any key under `[ghostty]` is forwarded verbatim to libghostty, using Ghostty's own kebab-case names (as in `ghostty +show-config` or the [Ghostty config reference](https://ghostty.org/docs/config/reference)). This is equivalent to dropping options into `~/.config/mistty/ghostty.conf`.

```toml
[ghostty]
theme = "Dracula"
font-feature = ["-calt", "-liga"]   # repeatable keys use a TOML array
macos-option-as-alt = true
```

Use it for themes and colors, advanced font rendering, mouse/selection behavior, shell integration, custom shaders, and anything else Ghostty supports.

**Keys Mistty manages and ignores here:** Mistty owns window geometry, splits, tabs, keybinds, the command/working-directory, title-bar style, and a handful of macOS window options — set those through Mistty's own keys (`[ui]`, `[shortcuts]`, etc.) instead. Transparency keys (`background-opacity`, `background-blur`) are currently denied because Mistty's window is opaque. The complete ignore list is documented inline in [`docs/config-example.toml`](../config-example.toml).

## `[[restore.command]]` — state restoration

When Mistty restarts, it restores your windows, sessions, tabs, panes, and working directories. Panes whose foreground process matches a restore rule relaunch that program; everything else comes back as a bare shell at the saved directory.

| Key        | Type         | Description                                                                                                         |
| ---------- | ------------ | ------------------------------------------------------------------------------------------------------------------- |
| `match`    | string       | Process basename to match (e.g. `nvim`, `ssh`). Required.                                                           |
| `strategy` | string       | Command to relaunch with. Omit to replay the captured `argv` verbatim (preserves arguments like `nvim mytext.txt`). |
| `env`      | inline table | Environment variables to set when relaunching.                                                                      |

```toml
[[restore.command]]
match = "nvim"                  # replays argv → reopens the same file
env = { MY_VAR = "{{pid}}" }    # the special {{pid}} token is replaced with the saved process pid

[[restore.command]]
match = "claude"
strategy = "claude --resume"    # explicit strategy replaces argv

[[restore.command]]
match = "ssh"                   # ssh user@host replayed with its args
```

## `[[popup]]` — popup windows

Transient floating terminal windows bound to a keyboard shortcut — handy for a scratch shell or a quick command. No popups ship by default; add one `[[popup]]` block each.

| Key             | Type   | Default         | Description                                               |
| --------------- | ------ | --------------- | --------------------------------------------------------- |
| `name`          | string | —               | Display name (also used by `mistty-cli popup toggle`).    |
| `command`       | string | —               | Command to run in the popup.                              |
| `shortcut`      | string | _(none)_        | Chord to toggle it (same grammar as `[shortcuts]`).       |
| `width`         | float  | `0.8`           | Fraction of screen width, `0.1`–`1.0`.                    |
| `height`        | float  | `0.8`           | Fraction of screen height, `0.1`–`1.0`.                   |
| `close_on_exit` | bool   | `true`          | Close the popup when the command exits.                   |
| `cwd`           | string | `"active_pane"` | Working directory source for the popup.                   |
| `shell_wrap`    | bool   | `true`          | Run `command` through a login shell rather than directly. |

```toml
[[popup]]
name = "lazygit"
command = "zsh -c lazygit"
shortcut = "Cmd-G"
shell_wrap = false
width = 0.75
height = 0.8
close_on_exit = true
```

Popups can also be opened, closed, toggled, and listed from the [CLI](cli.md#popup).
