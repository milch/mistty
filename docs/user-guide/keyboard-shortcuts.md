# Keyboard shortcuts

Every global and menu-bar shortcut in Mistty is rebindable from the `[shortcuts]` table in your config. This page lists the defaults; see [Configuration → Shortcuts](configuration.md#shortcuts) for the chord grammar and how to override them.

## Global shortcuts

### Tabs

| Action                      | Default             | Config key           |
| --------------------------- | ------------------- | -------------------- |
| New tab                     | `Cmd+T`             | `new_tab`            |
| New tab (don't inherit SSH) | `Cmd+Opt+T`         | `new_tab_plain`      |
| Next tab                    | `Cmd+]`, `Cmd+Down` | `next_tab`           |
| Previous tab                | `Cmd+[`, `Cmd+Up`   | `prev_tab`           |
| Rename tab                  | `Cmd+Shift+R`       | `rename_tab`         |
| Close tab                   | `Cmd+Ctrl+W`        | `close_tab`          |
| Focus tab 1–9               | `Cmd+1`…`Cmd+9`     | `focus_tab_modifier` |

### Panes

| Action                          | Default           | Config key               |
| ------------------------------- | ----------------- | ------------------------ |
| Split right                     | `Cmd+D`           | `split_horizontal`       |
| Split down                      | `Cmd+Shift+D`     | `split_vertical`         |
| Split right (don't inherit SSH) | `Cmd+Opt+D`       | `split_horizontal_plain` |
| Split down (don't inherit SSH)  | `Cmd+Shift+Opt+D` | `split_vertical_plain`   |
| Close pane                      | `Cmd+W`           | `close_pane`             |
| Window mode                     | `Cmd+X`           | `window_mode`            |

### Sessions

| Action            | Default                       | Config key               |
| ----------------- | ----------------------------- | ------------------------ |
| Session manager   | `Cmd+J`                       | `session_manager`        |
| Next session      | `Cmd+Opt+Down`, `Cmd+Shift+]` | `next_session`           |
| Previous session  | `Cmd+Opt+Up`, `Cmd+Shift+[`   | `prev_session`           |
| Move session down | `Cmd+Shift+Down`, `Cmd+Opt+]` | `swap_session_down`      |
| Move session up   | `Cmd+Shift+Up`, `Cmd+Opt+[`   | `swap_session_up`        |
| Rename session    | `Cmd+Opt+R`                   | `rename_session`         |
| Focus session 1–9 | `Ctrl+1`…`Ctrl+9`             | `focus_session_modifier` |

> **Why arrows and brackets differ:** `Cmd+Opt+arrows` _cycles_ sessions while `Cmd+Opt+brackets` _swaps_ them (and `Cmd+Shift` is the reverse). This is deliberate and designed to match keyboard shortcuts from other applications. Rebind them to unify if you prefer — see the [config notes](configuration.md#shortcuts).

### Windows

| Action               | Default       | Config key             |
| -------------------- | ------------- | ---------------------- |
| Close window         | `Cmd+Shift+W` | `close_window`         |
| Reopen closed window | `Cmd+Shift+T` | `reopen_closed_window` |

### Modes & UI

| Action                       | Default                | Config key       |
| ---------------------------- | ---------------------- | ---------------- |
| Copy mode                    | `Cmd+Shift+C`          | `copy_mode`      |
| Yank hints (link/path hints) | `Cmd+Shift+Y`          | `yank_hints`     |
| Toggle sidebar               | `Cmd+S`                | `toggle_sidebar` |
| Toggle tab bar               | `Cmd+Shift+B`          | `toggle_tab_bar` |
| Reload config                | _(unbound by default)_ | `reload_config`  |

A few actions exist with no default chord but can be bound manually: `reload_config`, `yank_hints_open`, `yank_hints_cursor`, and `reparent_session`. See the [config reference](configuration.md#shortcuts).
