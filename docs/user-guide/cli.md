# CLI

`mistty-cli` controls a running Mistty instance over a local Unix-domain socket. Use it to script your terminal: spin up sessions and panes, send keystrokes, run commands, and read back pane contents.

The Homebrew cask puts `mistty-cli` on your `PATH` automatically. A source build symlinks it into `~/.local/bin` (via `just run` / `just install`).

```sh
mistty-cli --help                  # top-level help
mistty-cli session --help          # help for a noun
mistty-cli version                 # client + running-app versions
```

## Output and IDs

Commands print human-readable text to a terminal and **JSON when piped** (so `| jq` works). Force the format with `--format json` (or `--format text`).

```sh
mistty-cli session list | jq '.[].id'
mistty-cli session list --format json
```

Most commands take a numeric ID. Where an ID accepts `0`, that means "the active one" (active pane, active session). Many commands default to the active target when the ID is omitted.

## session

Sessions are working-directory-scoped groups of tabs.

| Command | Description |
|---|---|
| `session list` | List all sessions |
| `session get <id>` | Session details |
| `session create` | Create a session |
| `session reparent <id> --directory <path>` | Change a session's working directory (new tabs inherit it; existing panes keep their live CWD) |
| `session close <id>` | Close a session |

`session create` options: `--name <label>`, `--directory <path>`, `--exec <command>`, `--window <id>` (defaults to the focused window).

```sh
mistty-cli session create --name api --directory ~/code/api
```

## tab

| Command | Description |
|---|---|
| `tab list --session <id>` | List tabs in a session |
| `tab get <id>` | Tab details |
| `tab create --session <id>` | Create a tab |
| `tab rename <id> <new-name>` | Rename a tab |
| `tab close <id>` | Close a tab |

`tab create` options: `--name <name>`, `--exec <command>`.

## pane

| Command | Description |
|---|---|
| `pane list --tab <id>` | List panes in a tab |
| `pane get <id>` | Pane details |
| `pane active` | The currently focused pane |
| `pane create --tab <id>` | Split a tab into a new pane |
| `pane focus [<id>]` | Focus a pane (by ID, or directionally — see below) |
| `pane resize <id> --direction <dir>` | Resize a pane |
| `pane close <id>` | Close a pane |
| `pane send-keys <keys> [--pane <id>]` | Type keys into a pane |
| `pane run-command <cmd> [--pane <id>]` | Run a command in a pane |
| `pane get-text [--pane <id>]` | Read a pane's visible text |

Details:

- `pane create` options: `--tab <id>`, `--direction horizontal|vertical`.
- `pane focus` takes a pane ID, **or** `--direction left|right|up|down` with `--session <id>` (`0` = active session) to move focus relative to the current pane.
- `pane resize` options: `--direction up|down|left|right`, `--amount <n>` (default `1`).
- `pane send-keys`, `run-command`, and `get-text` default to `--pane 0` (the active pane).

```sh
# Run a build in the active pane and read the result
mistty-cli pane run-command "npm run build"
mistty-cli pane get-text | tail -n 20

# Split the active tab and focus the new pane to the right
mistty-cli pane create --tab 1 --direction horizontal
mistty-cli pane focus --direction right --session 0
```

## window

| Command | Description |
|---|---|
| `window list` | List all windows |
| `window get <id>` | Window details |
| `window create` | Open a new window |
| `window focus <id>` | Focus a window |
| `window close <id>` | Close a window |

## popup

Drives the popup windows defined in your [config](configuration.md#popup--popup-windows).

| Command | Description |
|---|---|
| `popup list` | List open popups |
| `popup open` | Open a popup |
| `popup toggle <name>` | Toggle a named popup (from config) |
| `popup close <id>` | Close a popup |

`popup open` options: `--name <name>`, `--exec <command>`, `--width <0–1>`, `--height <0–1>`, `--close-on-exit` / `--keep-on-exit`, `--session <id>`. `popup toggle` / `open` default to the active session.

```sh
mistty-cli popup toggle scratch
```

## config

| Command | Description |
|---|---|
| `config show` | Print the resolved Ghostty configuration Mistty forwards |
| `config reload [--config <path>]` | Tell the running app to re-read `~/.config/mistty/config.toml` |

`config reload` is the scriptable equivalent of the `reload_config` shortcut — handy after editing your config from elsewhere.

## debug

| Command | Description |
|---|---|
| `debug state` | Print the live workspace snapshot (windows → sessions → tabs → panes) as JSON |

Useful for inspecting IDs and structure when scripting:

```sh
mistty-cli debug state | jq '.windows[].sessions[].tabs[].panes[].id'
```

## version

```sh
mistty-cli version
```

Prints the `mistty-cli` client version alongside the running `Mistty.app` server version — a quick way to confirm the CLI is talking to the app you expect.
