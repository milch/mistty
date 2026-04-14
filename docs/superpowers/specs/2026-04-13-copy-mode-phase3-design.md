# Copy Mode Phase 3 — Yank Hints

Status: design
Date: 2026-04-13

## Summary

Add a tmux-thumbs / vimium-style hint mode to copy mode. User presses `y`
(copy) or `o` (open) with no selection active; detectors scan the visible
viewport for URLs, paths, hashes, quoted strings, etc.; each match gets a
short label; typing the label copies or opens the match.

## Goals

- Keyboard-only extraction of common patterns from terminal output
- Zero mouse selection for the vast majority of copy cases
- Consistent with existing copy mode state machine (Phase 1/2)

## Non-goals (deferred)

- Smart per-pattern open dispatch (git hash → `git show`, port → localhost URL)
- Full-scrollback scanning (viewport-only, re-scan on scroll)
- Multi-pick / stay-in-mode after selection
- User-defined custom pattern regexes

## Entry points

| Trigger | Context | Default action |
|---|---|---|
| `y` | In copy mode, no selection | copy (pattern hints) |
| `o` | In copy mode (selection or not) | open (pattern hints) |
| `Y` | In copy mode, no selection | copy (line hints) |
| `cmd+shift+y` | Any pane, not in copy mode | enter copy mode + pattern hint mode (copy) |

`y` with an active selection retains existing behavior (yank selection).
`Y` is unused prior to this feature, so no conflict.

## Line hint mode

A second hint flavor triggered by `Y`. Instead of pattern detectors, it
generates one match per **non-empty visible line**. The match range is
the whole line (first non-whitespace column through last non-whitespace
column); yanking copies the line's text (trimmed of trailing
whitespace, not indentation).

Labels, alphabet, ordering (bottom-to-top), input handling, case
semantics, dim/pill rendering, scroll re-scan, and exit behavior are
**identical to pattern hint mode**. Only differences:

- Detector: "non-empty visible lines" rather than regex patterns.
- No `open` default — line hint mode only copies. Uppercase still swaps
  per `uppercase_action`, so a user who configured `uppercase_action =
  "copy"` with lowercase-open would still be able to open a line's
  text via lowercase — but realistically lines are noise to `open(1)`;
  documented as such, not specially prevented.
- Label pill placed at the left edge of the line (column 0), not in
  front of the match content.

Mode indicator: `-- HINT (line) --`.

## Detectors

Run per visible line, except where noted. Each detector produces matches
with `(startRow, startCol, endRow, endCol)` viewport coordinates.

| Kind | Sketch | Notes |
|---|---|---|
| `url` | `\b(https?\|ftp\|file\|ssh\|git)://[^\s<>"')\]]+` | strip trailing `.,;:)]}` |
| `email` | `\b[\w.+-]+@[\w-]+\.[\w.-]+\b` | |
| `uuid` | `\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b` | case-insensitive |
| `path` | `(?:~\|\.{1,2})?/[\w./\-_]+` | must contain `/` |
| `hash` | `\b[0-9a-f]{7,40}\b` | hex |
| `ipv4` / `ipv6` | standard patterns | |
| `envVar` | `\b[A-Z][A-Z0-9_]{2,}\b` | ≥3 uppercase chars w/ `_` allowed |
| `number` | `\b\d{2,}\b` | ports/PIDs, ≥2 digits |
| `quoted` | `"[^"]+"` and `'[^']+'` | **container** |
| `codeSpan` | `` `[^`]+` `` | **container** |

### Conflict resolution

Peer matches (everything except containers) resolved by:

1. Longest match wins.
2. Ties broken by priority order above (url highest).

Container matches (`quoted`, `codeSpan`) are transparent: their inner
region is also scanned for peer matches, and both the container match
and inner matches receive hints. This lets `` `abc123def` `` yield a
hint for the whole code span *and* a hint for the hash inside.

## Labels

### Alphabet

Configurable:

```toml
[copy_mode.hints]
alphabet = "asdfghjkl"   # default: home row
uppercase_action = "open" # "open" | "copy"; lowercase takes the other
```

### Generation

tmux-thumbs algorithm, given N matches and alphabet size K:

- If N ≤ K: assign first N chars as single-char labels.
- If N > K: reserve trailing chars of the alphabet as 2-char prefixes,
  emitting single-char labels from the front of the alphabet for the
  first matches and 2-char labels for the rest. Reserve the minimum
  number of prefixes needed to cover N.

### Ordering

Matches are assigned labels in **bottom-to-top, left-to-right** viewport
order. Bottommost matches get the shortest / earliest labels.

### Case semantics

- Lowercase label input → run the **default** action (set by entry key:
  `y` = copy, `o` = open, `cmd+shift+y` = copy).
- Uppercase label input → run the **other** action (swap governed by
  `uppercase_action`).

So with defaults: entered via `y`, typing `a` copies; typing `A` opens.

## Input handling

- First keystroke:
  - Matches a single-char label → execute immediately.
  - Matches the first char of one or more 2-char labels → store as
    `typedPrefix`, re-render with non-matching hints dimmed.
  - Else (not in alphabet, not a prefix) → exit hint mode back to copy
    mode, cursor where it was.
- Second keystroke (after prefix):
  - Matches a 2-char label → execute.
  - Else → exit hint mode.
- `Esc` → exit hint mode.
- No backspace support — a wrong key exits.

Case is preserved through the prefix: `As` and `as` select the same
hint but run different actions.

## Execution

- **copy:** write match text to the system clipboard via
  `NSPasteboard.general`, then exit hint mode **and** copy mode.
- **open:** pass match text to `NSWorkspace.shared.open(URL(...))` for
  URL-shaped matches; else `Process.launch` of `/usr/bin/open <text>`.
  Exit hint mode and copy mode. Non-openable text is still handed to
  `open(1)`, which will fail visibly — no smart dispatch in v1.

## Rendering

New `CopyModeHintOverlay` SwiftUI view, layered over the terminal
surface using the existing coordinate mapping (same approach as search
highlight from Phase 2).

- Full viewport dimmed with a ~40%-opacity dark layer.
- Match regions drawn at full brightness on top of the dim layer.
- Each match gets a small pill-shaped label positioned immediately
  before `startCol` on `startRow`: bold terminal font, accent-color
  background, high-contrast foreground.
- When `typedPrefix` is non-empty: labels whose first char differs from
  `typedPrefix` are heavily dimmed; remaining labels bold their
  remaining char.

Mode indicator: extend the existing mode readout to `-- HINT (copy) --`
or `-- HINT (open) --`.

Help overlay (`g?`): add a hint-mode section documenting alphabet,
case semantics, and exit key.

### Scroll behavior

On any scroll delta while in hint mode, re-read the visible viewport
text, re-run detectors, re-generate labels. Cursor position is
unchanged. This is **Option B** from Q7 — no persistent cross-viewport
hint state.

## State machine

Extend the existing action-based state machine.

```swift
enum HintAction { case copy, open }
enum HintSource { case patterns, lines }

struct HintMatch {
    let range: TerminalRange
    let text: String
    let kind: HintKind
}

struct HintState {
    let action: HintAction        // default from entry key
    let source: HintSource        // patterns or lines
    var matches: [HintMatch]      // bottom→top, left→right
    var labels: [String]          // index-aligned
    var typedPrefix: String       // "" or single char
}

// CopyModeState.mode gains:
case hint(HintState)

// CopyModeAction gains:
case enterHintMode(HintAction, HintSource)
case hintInput(Character)
case exitHintMode
case copyText(String)
case openItem(String)
```

`handleKey` routing additions:

- In `.copy`/no-selection with key `y` → `.enterHintMode(.copy, .patterns)`.
- In any copy mode with key `o` → `.enterHintMode(.open, .patterns)`.
- In `.copy`/no-selection with key `Y` → `.enterHintMode(.copy, .lines)`.
- In `.hint` → interpret key per Input handling above, emitting
  `.hintInput(c)` (updates `typedPrefix`), or
  `[.copyText(s), .exitHintMode, .exitCopyMode]`, or
  `[.openItem(s), .exitHintMode, .exitCopyMode]`, or
  `.exitHintMode`.

`ContentView` consumes `.copyText` / `.openItem` and performs the
clipboard write / `NSWorkspace.open`. `cmd+shift+y` in the global key
handler emits `[.enterCopyMode, .enterHintMode(.copy)]`.

## Files

### New

- `Mistty/Models/HintDetector.swift` — regex detectors + conflict resolution + line source
- `Mistty/Models/HintLabels.swift` — label generation
- `Mistty/Models/HintState.swift` — sub-state types
- `Mistty/Views/Terminal/CopyModeHintOverlay.swift`
- `MisttyTests/Models/HintDetectorTests.swift`
- `MisttyTests/Models/HintLabelsTests.swift`
- `MisttyTests/Models/CopyModeHintIntegrationTests.swift`

### Modified

- `Mistty/Models/CopyModeAction.swift`
- `Mistty/Models/CopyModeState.swift`
- `Mistty/Views/Terminal/CopyModeHelpOverlay.swift`
- `Mistty/App/ContentView.swift`
- Config loading (wherever `[copy_mode]` is parsed today)

## Testing

**`HintDetectorTests`** — per-pattern fixtures incl. URLs with
trailing punctuation, UUIDs, paths with `~`, overlap of path inside
URL (longest wins), hash inside backticks (both hints emitted), env
var vs number disambiguation.

**`HintLabelsTests`** — N=1, N=K, N=K+1, N=K², verify labels unique,
single-char labels assigned to bottommost matches, deterministic
ordering.

**`CopyModeHintIntegrationTests`** — enter via `y`/`o`/`Y`/`cmd+shift+y`;
single-char selection copies and exits copy mode; 2-char selection;
uppercase swaps action; mismatched key exits hint mode (remains in
copy mode); scroll re-scans; line mode yanks full line text excluding
trailing whitespace; line mode skips blank lines.

## Configuration summary

```toml
[copy_mode.hints]
alphabet = "asdfghjkl"
uppercase_action = "open"
```

Both fields optional with the defaults shown.
