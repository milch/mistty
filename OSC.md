# OSC sequences supported by Ghostty

OSC (Operating System Command) sequences are escape sequences that begin with
`ESC ]` and end with either `ST` (`ESC \`, 0x9c) or `BEL` (0x07). They carry
free-form string payloads used to interact with the terminal emulator's
environment (titles, colors, clipboard, notifications, etc).

This document enumerates every OSC sequence that Ghostty's parser recognizes on
`main` as of commit `7629c4ba8`. "Recognized" here means the state machine and
the corresponding parser produce a command variant. Some commands are
produced but intentionally ignored by Ghostty (noted where applicable). Some
OSCs have sub-dispatches (e.g. OSC 9 splits into iTerm2 notifications and a
family of ConEmu extensions).

Source: `src/terminal/osc.zig` plus `src/terminal/osc/parsers/*.zig`.

## Format

Each section lists:

- **Sequence** — the literal OSC number and its parameter shape.
- **What it does** — short description of the behavior.
- **Notes** — parsing details, Ghostty-specific behavior, or references.

Where `Pt` is used below it refers to a free-form text payload.

---

## Window metadata

### OSC 0 — Set window (icon + title)

```
ESC ] 0 ; Pt ST
```

Sets both the window title and icon name. Ghostty uses this to update the
window title. Title-mode state (from DECSET) governs encoding: hex-encoded
UTF-8 when title mode 0 is active, otherwise UTF-8 or Latin-1. Invalid UTF-8
is logged and dropped.

### OSC 1 — Set icon name

```
ESC ] 1 ; Pt ST
```

Sets the icon name. Parsed but ignored by Ghostty (logged at info) because
icon names are not well-defined across platforms. Parsing prevents log spam
from unhandled OSCs.

### OSC 2 — Set window title

```
ESC ] 2 ; Pt ST
```

Sets the window title only (no icon). Same payload handling as OSC 0.

---

## Color operations

Ghostty groups a family of color OSCs into a single `color_operation`
command with multiple sub-operations per request. The same sequence may
carry multiple `;`-separated requests, each of which may *set*, *query*
(`?` as the spec), or *reset* a color.

### OSC 4 — Palette color set/query

```
ESC ] 4 ; c ; spec [ ; c ; spec ... ] ST
```

Sets or queries palette index `c` (0–255) or a "special" color mapped from
indexes 256–260 (bold=256, underline=257, blink=258, reverse=259, italic=260).
`spec` is an X-style color spec (`#rrggbb`, `rgb:rr/gg/bb`, a named color,
etc.) or `?` to query the current value. Partial failures return results
accumulated so far, matching xterm's lenient behavior.

### OSC 5 — Special color set/query

```
ESC ] 5 ; c ; spec ST
```

Same as OSC 4 but `c` is a "special" index (0=bold, 1=underline, 2=blink,
3=reverse, 4=italic). Controls the color used to render SGR attributes.

### OSC 10 — Default foreground color

```
ESC ] 10 ; spec ST
```

Set or query the terminal's foreground color. Successive specs in a single
sequence roll forward through the dynamic color list (10→11→12→…→19),
matching xterm.

### OSC 11 — Default background color

Set or query the background color.

### OSC 12 — Text cursor color

Set or query the cursor color.

### OSC 13 — Mouse pointer foreground

Set or query the mouse pointer (cursor icon) foreground. Parsed; Ghostty does
not act on it.

### OSC 14 — Mouse pointer background

Set or query the mouse pointer background. Parsed; Ghostty does not act on it.

### OSC 15 — Tektronix foreground

Reserved for Tektronix emulation. Parsed; not acted on.

### OSC 16 — Tektronix background

As above.

### OSC 17 — Selection (highlight) background

Set or query the selection highlight background color.

### OSC 18 — Tektronix cursor

Parsed; not acted on.

### OSC 19 — Selection (highlight) foreground

Set or query the selection highlight foreground color.

### OSC 104 — Reset palette color(s)

```
ESC ] 104 [ ; c [ ; c ... ] ] ST
```

Reset one or more palette indexes to their defaults. With no parameters,
resets the entire palette.

### OSC 110 — Reset foreground

Reset the default foreground color.

### OSC 111 — Reset background

Reset the default background color.

### OSC 112 — Reset cursor color

Reset the text cursor color.

### OSC 113 — Reset pointer foreground

### OSC 114 — Reset pointer background

### OSC 115 — Reset Tektronix foreground

### OSC 116 — Reset Tektronix background

### OSC 117 — Reset selection background

### OSC 118 — Reset Tektronix cursor

### OSC 119 — Reset selection foreground

All the 11x resets mirror the corresponding 1x setter.

> **Note on OSC 105:** the `Operation.osc_105` enum variant exists in the code
> but there is no state-machine transition that reaches it — it is not
> currently reachable from input and therefore not supported at runtime.

### OSC 21 — Kitty color protocol

```
ESC ] 21 ; key[=value] [ ; key[=value] ... ] ST
```

Set, reset, or query multiple named colors in one sequence, per the
[Kitty color protocol](https://sw.kovidgoyal.net/kitty/color-stack/#id1).
`key` names a palette slot or a semantic slot (`foreground`, `background`,
`cursor`, `cursor_text`, `visual_bell`, `selection_foreground`,
`selection_background`, numeric palette index, etc.). `value` is an X color
spec, `?` to query, or empty to reset. Requires an allocator.

---

## Shell / session metadata

### OSC 7 — Report current working directory

```
ESC ] 7 ; file://host/path ST
```

Reports the shell's current working directory as a `file://` URL. Ghostty
stores it unparsed (validation is up to the consumer). The spec for this
sequence is "moderately flawed" per the
[terminal-wg issue](https://gitlab.freedesktop.org/terminal-wg/specifications/-/issues/20)
but it is widely supported so Ghostty implements it.

### OSC 8 — Hyperlink start/end

```
ESC ] 8 ; params ; URI ST    (start)
ESC ] 8 ; ; ST                (end)
```

Begins or ends a terminal hyperlink. `params` is a colon-separated list of
`key=value` pairs; Ghostty currently honors `id=<string>` (unknown options
are logged and skipped). An empty URI with a non-empty `id` is rejected;
otherwise an empty URI produces a `hyperlink_end` command.

### OSC 22 — Set mouse pointer shape

```
ESC ] 22 ; name ST
```

Sets the mouse pointer shape by name. Ghostty accepts the W3C CSS cursor
names (what Foot uses). Unknown names are logged and ignored.

### OSC 52 — Manipulate clipboard

```
ESC ] 52 ; Pc ; Pd ST
```

Get (`Pd = "?"`), set (`Pd = base64`), or clear (`Pd = ""`) the clipboard.
`Pc` is a clipboard selector character (`c` for clipboard — the default
if empty, `s` for system/selection, `p` for primary, etc.). Ghostty
accepts the selector character verbatim and passes the base64 blob through
for higher-level validation.

### OSC 66 — Kitty text sizing protocol

```
ESC ] 66 ; s=... : w=... : n=... : d=... : v=... : h=... ; text ST
```

Renders `text` with the requested scale, width, numerator/denominator
fraction, and vertical/horizontal alignment per
[Kitty's text sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/).
Keys: `s` scale (1–7), `w` width cells (0 = default), `n`/`d` scale
fraction, `v` ∈ {top, bottom, center}, `h` ∈ {left, right, center}.
Payload is capped at 4096 bytes and must be URL-safe UTF-8.

### OSC 133 — Semantic prompts

```
ESC ] 133 ; action [ ; options ] ST
```

Per the
[semantic prompt proposal](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md).
Actions:

- `L` — fresh line (start on a blank line without clearing).
- `A` — fresh line and mark the start of a new prompt.
- `N` — new command (Ghostty-extension; begin a new command group).
- `P` — prompt start.
- `B` — end of prompt / start of user input.
- `I` — end of prompt / start of input, terminated at EOL.
- `C` — end of input / start of command output.
- `D` — end of command (optional numeric exit code follows).

Options (Ghostty's superset of the spec, parsed lazily via `readOption`):

- `aid=<id>` — aid identifier.
- `cl=<line|cell|…>` — click behavior hint.
- `k=<prompt_kind>` — prompt kind (primary, continuation, …).
- `err=<message>` — error message for the prompt.
- `cmdline=<q-encoded>` — the full command line, q-encoded.
- `cmdline_url=<url-encoded>` — the full command line, URL-percent-encoded.
- `redraw=<0|1|last>` — Kitty redraw hint, extended by Ghostty with `last`.
- `special_key=<bool>` — shell supports a special cursor-movement key.
- `click_events=<bool>` — shell handles mouse click events natively.
- `exit_code=<int>` — exit code (positional, used by `D`).

---

## Notifications

### OSC 9 — iTerm2 desktop notification (fallback)

```
ESC ] 9 ; message ST
```

When the subcommand prefix does not match a ConEmu extension, OSC 9 is
interpreted as an iTerm2-style desktop notification with an empty title and
`message` as the body.

### OSC 777 — rxvt notify extension

```
ESC ] 777 ; notify ; title ; body ST
```

rxvt's extension for desktop notifications with both a title and body.
Extensions other than `notify` are logged and rejected.

---

## ConEmu extensions (OSC 9;N)

These subcommands of OSC 9 come from ConEmu. Reference:
<https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC>.

### OSC 9;1 — Sleep

```
ESC ] 9 ; 1 ; milliseconds ST
```

Pause processing for `milliseconds` (default 100 ms if missing/invalid,
clamped to 10,000 ms). If the payload isn't a valid `9;1;<digits>` form it
falls through to the OSC 9 desktop-notification interpretation.

### OSC 9;2 — Show GUI message box

```
ESC ] 9 ; 2 ; message ST
```

Pops up a host-provided message box. Empty messages are permitted.

### OSC 9;3 — Change tab title

```
ESC ] 9 ; 3 ; title ST   (set)
ESC ] 9 ; 3 ;        ST  (reset to default)
```

Sets or resets the tab title. With no payload after the trailing `;` the
command resolves to `reset`.

### OSC 9;4 — Progress report

```
ESC ] 9 ; 4 ; state [ ; progress ] ST
```

Taskbar-style progress reporting. State values:

- `0` — remove progress indicator.
- `1` — set (progress in 0–100; defaults to 0 when omitted).
- `2` — error state (optional progress).
- `3` — indeterminate.
- `4` — pause (optional progress).

Progress is clamped to 0–100.

### OSC 9;5 — Wait for input

```
ESC ] 9 ; 5 ST
```

Signals that the host wants user input before continuing.

### OSC 9;6 — GUI macro

```
ESC ] 9 ; 6 ; macro ST
```

Runs a host GUI macro. Parsed; dispatch is up to the apprt.

### OSC 9;7 — Run process

```
ESC ] 9 ; 7 ; commandline ST
```

Asks the host to run a process. Parsed; dispatch is up to the apprt.

### OSC 9;8 — Output environment variable

```
ESC ] 9 ; 8 ; NAME ST
```

Requests the value of environment variable `NAME` be written back to the
pty.

### OSC 9;9 — Current working directory (ConEmu)

```
ESC ] 9 ; 9 ; path ST
```

Alternate "report cwd" path, emitted by ConEmu-aware shells. Ghostty maps
this onto the same `report_pwd` command produced by OSC 7.

### OSC 9;10 — XTerm keyboard / output emulation

```
ESC ] 9 ; 10           ST  (on, on)
ESC ] 9 ; 10 ; 0       ST  (off, off)
ESC ] 9 ; 10 ; 1       ST  (on, on)
ESC ] 9 ; 10 ; 2       ST  (no-change, off)
ESC ] 9 ; 10 ; 3       ST  (no-change, on)
```

Toggles ConEmu's xterm keyboard and output emulation modes.

### OSC 9;11 — Comment

```
ESC ] 9 ; 11 ; comment ST
```

Host-visible comment / annotation string. Parsed; dispatch is up to the
apprt.

### OSC 9;12 — Mark prompt start

```
ESC ] 9 ; 12 ST
```

Alias for OSC 133 `A` (fresh line + mark new prompt); Ghostty produces the
same `semantic_prompt` command as OSC 133;A.

---

## iTerm2 extensions (OSC 1337)

```
ESC ] 1337 ; Key[=Value] ST
```

Ghostty recognizes the OSC 1337 key names (ASCII case-insensitive) but
currently only acts on a subset:

- `Copy=:<base64>` — set the clipboard (maps to the `clipboard_contents`
  command with kind `c`). Unlike OSC 52 it does not accept `?` (query) or
  an empty value, and the base64 must be prefixed with `:`.
- `CurrentDir=<path>` — report the current working directory. Maps to
  `report_pwd` (same target as OSC 7).

The following keys are recognized but produce no command (logged as
"unimplemented" and the sequence is dropped):

`AddAnnotation`, `AddHiddenAnnotation`, `Block`, `Button`,
`ClearCapturedOutput`, `ClearScrollback`, `CopyToClipboard`, `CursorShape`,
`Custom`, `Disinter`, `EndCopy`, `File`, `FileEnd`, `FilePart`,
`HighlightCursorLine`, `MultipartFile`, `OpenURL`, `PopKeyLabels`,
`PushKeyLabels`, `RemoteHost`, `ReportCellSize`, `ReportVariable`,
`RequestAttention`, `RequestUpload`, `SetBackgroundImageFile`,
`SetBadgeFormat`, `SetColors`, `SetKeyLabel`, `SetMark`, `SetProfile`,
`SetUserVar`, `ShellIntegrationVersion`, `StealFocus`, `UnicodeVersion`.

Unknown keys are dropped silently.

Reference: <https://iterm2.com/documentation-escape-codes.html>.

---

## Kitty clipboard protocol (OSC 5522)

```
ESC ] 5522 ; metadata [ ; payload ] ST
```

Implements [Kitty's clipboard protocol](https://sw.kovidgoyal.net/kitty/clipboard/).
`metadata` is a `:`-separated list of `key=value` pairs. Recognized keys:

- `type=<read|write|walias|wdata>` — the operation.
- `loc=<primary>` — clipboard location.
- `mime=<mime/type>` — payload MIME type.
- `name=<string>` — named entry (for walias/wdata).
- `id=<identifier>` — request identifier (alphanumerics plus `-_+.`).
- `password=<string>`, `pw=<string>` — authorization.
- `status=<DATA|DONE|EBUSY|EINVAL|EIO|ENOSYS|EPERM|OK>` — for responses.

The payload may be base64 (indicated by an `e` flag in the metadata). Needs
an allocator because payloads can be large.

---

## Hierarchical context signalling (OSC 3008)

```
ESC ] 3008 ; (start|end) = <id> [ ; key=value ... ] ST
```

Implements the [UAPI OSC-context spec](https://uapi-group.org/specifications/specs/osc_context/).
Contexts are hierarchical (stacked) and identified by a 1–64-character ASCII
token (bytes 32–126).

Actions:

- `start=<id>` — initiate, update, or return to a context.
- `end=<id>` — terminate a context.

Recognized metadata fields (parsed lazily via `readOption`):

- `type=<boot|container|vm|elevate|chpriv|subcontext|remote|shell|command|app|service|session>`
- `user=<string>`
- `hostname=<string>`
- `machineid=<string>`
- `bootid=<string>`
- `pid=<u64>`
- `pidfdid=<u64>`
- `comm=<string>`
- `cwd=<string>`
- `cmdline=<string>`
- `vm=<string>`
- `container=<string>`
- `targetuser=<string>`
- `targethost=<string>`
- `sessionid=<string>`
- `exit=<success|failure|crash|interrupt>` (end sequences)
- `status=<u64>` (end sequences)
- `signal=<string>` (end sequences)

Unknown or malformed fields are ignored per the specification.

---

## Parser internals worth knowing

- Maximum "normal" OSC payload is 2048 bytes (`Parser.MAX_BUF`). Most
  parsers fail closed when exceeded.
- OSCs 52 and 5522 fall back to an allocating buffer so large clipboard
  payloads fit.
- OSCs that need an allocator (OSC 4/5, 10–19, 104, 110–119, 21) mark the
  sequence invalid if the parser was initialized without one.
- The terminator is tracked per command (`ST` vs `BEL`) so response
  sequences (e.g. color query replies) can echo the same terminator the
  caller used.
- The following prefix states are parsed-but-inert (no command produced):
  `OSC 3`, `OSC 30`, `OSC 300`, `OSC 6`, `OSC 55`, `OSC 77`, `OSC 552`.
  They exist solely so longer-prefixed OSCs (3008, 66, 777, 5522) can be
  reached through the state machine.
