# Copy mode

Copy mode is Mistty's keyboard-driven layer for working in scrollback: move a cursor with vim-style motions, select text, search, and yank without using the mouse. Layered on top is **hint mode**, which labels every URL, file path, and a few other types of tokens on screen so you can copy or open one with a couple of keystrokes (think tmux-thumbs / vimium).

Enter copy mode with `Cmd+Shift+C`. Press `g?` at any time for an in-app cheat sheet, and `Esc` to leave.

## Navigation

| Key             | Motion                                     |
| --------------- | ------------------------------------------ |
| `h` `j` `k` `l` | Move cursor left / down / up / right       |
| `w` `b` `e`     | Word forward / back / end                  |
| `W` `B` `E`     | WORD motions (whitespace-delimited)        |
| `ge` / `gE`     | End of previous word / WORD                |
| `0` / `$`       | Start / end of line                        |
| `gg` / `G`      | Top / bottom of scrollback                 |
| `H` / `M` / `L` | Viewport top / middle / last line          |
| `[count]`       | Prefix any motion to repeat it (e.g. `5j`) |

## Selection

| Key      | Action                              |
| -------- | ----------------------------------- |
| `v`      | Visual (character) selection        |
| `V`      | Visual line selection               |
| `Ctrl-v` | Visual block selection              |
| `Esc`    | Clear the selection                 |
| `y`      | Yank the selection to the clipboard |

## Find on line

| Key       | Action                                            |
| --------- | ------------------------------------------------- |
| `f` / `F` | Jump to next / previous occurrence of a character |
| `t` / `T` | Jump just before the next / previous character    |
| `;`       | Repeat the last find                              |
| `,`       | Repeat the last find, reversed                    |

## Search

| Key | Action          |
| --- | --------------- |
| `/` | Search forward  |
| `?` | Search backward |
| `n` | Next match      |
| `N` | Previous match  |

## Scrolling

| Key                 | Action              |
| ------------------- | ------------------- |
| `Ctrl-D` / `Ctrl-U` | Half page down / up |
| `Ctrl-F` / `Ctrl-B` | Full page down / up |

To keep a few rows of context visible above and below the cursor as you move (like vim's `scrolloff`), set [`copy_mode.scrolloff`](configuration.md#copy-mode) in your config.

## Actions

| Key   | Action                               |
| ----- | ------------------------------------ |
| `y`   | Yank the selection, or confirm hints |
| `g?`  | Toggle the help overlay              |
| `gh`  | Toggle the hint toast                |
| `Esc` | Exit copy mode                       |

## Hint mode

Hint mode overlays a short letter label on every URL, file path, and some other types of tokens visible in the pane. Type a label to act on its target. You can trigger it from inside copy mode:

| Key (after entering copy mode) | Action                                                                         |
| ------------------------------ | ------------------------------------------------------------------------------ |
| `y`                            | Show hints, then **copy** the chosen target to the clipboard                   |
| `o`                            | Show hints, then **open** the chosen target (`open $TEXT`)                     |
| `Y`                            | Hint whole lines rather than detected URLs/paths                               |
| `c`                            | Show hints, then move the **cursor** to the chosen label and stay in copy mode |

Or you can jump straight to the hint mode from anywhere, without triggering copy mode first:

| Key (outside of copy mode) | Action                                                                         |
| -------------------------- | ------------------------------------------------------------------------------ |
| `Cmd+Shift+Y`              | Show hints, then **copy** the chosen target to the clipboard                   |
| `Cmd+Shift+O`              | Show hints, then **open** the chosen target (`open $TEXT`)                     |
| `Ctrl+Cmd+Y`               | Show hints, then move the **cursor** to the chosen label and stay in copy mode |

Once hints are showing:

| Key                 | Action                                           |
| ------------------- | ------------------------------------------------ |
| label letters       | Select that hint and run the active action       |
| `A`–`Z` (uppercase) | Run the _alternate_ action on that hint          |
| `1` / `2` / `3`     | Switch the active action to copy / open / cursor |
| `Esc`               | Cancel                                           |

By default, lowercase labels **copy** and uppercase labels **open**. You can flip this, change the cursor-jump behavior, and choose which letters are used for labels via [`[copy_mode.hints]`](configuration.md#copy-mode-hints) — `alphabet` and `uppercase_action`.

## Related configuration

- [`[copy_mode]`](configuration.md#copy-mode) — `scrolloff`
- [`[copy_mode.hints]`](configuration.md#copy-mode-hints) — `alphabet`, `uppercase_action`
- [Keyboard shortcuts](keyboard-shortcuts.md) — rebind `copy_mode` and `yank_hints`
