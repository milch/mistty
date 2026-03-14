# Fuzzy Finding & "New" Option for Session Manager

## Overview

Replace the session manager's substring filtering with a typo-tolerant fuzzy matcher, add match highlighting in results, and introduce a "New" option that lets users create sessions directly from the search query.

## Fuzzy Matching Algorithm

### FuzzyMatcher

A `FuzzyMatcher` struct with a single entry point:

```swift
struct FuzzyMatch {
    let score: Double         // 0.0...1.0, higher is better
    let matchedIndices: [Int] // character indices in target that matched
}

struct FuzzyMatcher {
    static func match(query: String, target: String) -> FuzzyMatch?
}
```

Returns `nil` when the query cannot match the target even with typo tolerance. Case-insensitive.

### Matching Pipeline

1. **Strict ordered match** — all query characters appear in the target in order (fzf-style). If found, score normally.
2. **Typo-tolerant fallback** — if strict match fails, use a sliding window approach: for each window of length `query.count ± max edits` in the target, compute Damerau-Levenshtein distance. If the best window's distance is within the allowed edits, return a match with a 0.5x score penalty. The `matchedIndices` for a typo match are all indices within the best-matching window (the entire substring is highlighted). This is acceptable because typo matches are short substrings close in length to the query.

Max allowed edits:
- Query length 1-3: 0 edits (too short for meaningful typo tolerance, strict only)
- Query length 4-6: 1 edit
- Query length 7+: 2 edits

### Scoring Heuristics (Strict Match)

Each matched character accumulates points based on:
- **Consecutive run bonus** — characters matching consecutively score higher than scattered matches
- **Word boundary bonus** — matching right after `/`, `-`, `_`, `.`, or space
- **Prefix bonus** — matching at the very start of the target
- **Shorter target bonus** — matching 3/4 chars ranks higher than matching 3/20 chars

For typo-tolerant matches, the base score is reduced by a penalty factor (0.5x) so strict matches always rank above typo matches of similar quality.

### Multi-Token AND Logic

The query is split by spaces into tokens. Empty tokens (from consecutive spaces or leading/trailing spaces) are discarded. If no non-empty tokens remain, the query is treated as empty.

Each token must match somewhere in the item's matchable fields. Tokens can match across different fields of the same item (e.g. for SSH host with alias "production" and hostname "prod.example.com", query "prod exam" can match "prod" against alias and "exam" against hostname).

The final score is the minimum of per-token scores. The `matchedIndices` are the union of all token matches.

For `ItemMatchResult`, when tokens match different fields, store `field = .displayName` (the primary field). The view highlights matched characters in whichever field they belong to — both `displayName` and `subtitle` can have highlights simultaneously in multi-token scenarios.

Example: "work bazel" requires both "work" AND "bazel" to match. An item like `~/workspace/bazel-project` would match both tokens.

### SSH Boost

If the first token is "ssh" (case-insensitive), SSH host items receive a 1.5x score multiplier. The "ssh" token is still matched normally against all items — the boost just ensures SSH hosts surface at the top when the user's intent is clearly SSH.

### Matchable Fields Per Item Type

| Item Type | Fields Matched | Display Highlighted |
|-----------|---------------|-------------------|
| Running session | session name (subtitle is nil, name only) | display name |
| Directory | basename, full path (best score wins) | whichever field matched better |
| SSH host | alias, hostname if non-nil (best score wins, skip nil hostname) | whichever field matched better |

The raw name is matched, not the display prefix ("▶ " or "⌁ ").

### Multi-Field Match Result

When matching against multiple fields (e.g. basename + full path for directories), the view model stores which field produced the best match:

```swift
struct ItemMatchResult {
    let score: Double                    // overall score (minimum of per-token scores)
    let displayNameIndices: [Int]        // matched character indices in display name
    let subtitleIndices: [Int]           // matched character indices in subtitle
}
```

The view model stores `matchResults: [SessionManagerItem.ID: ItemMatchResult]` so the view can highlight matched characters in both the display name and subtitle independently.

## "New" Option

### New SessionManagerItem Case

```swift
case newSession(query: String, directory: URL, createDirectory: Bool, sshCommand: String?)
```

- `sshCommand` is the resolved SSH command string (e.g. "ssh myhost") when in SSH mode, `nil` otherwise. This avoids re-parsing the query at confirmation time.
- The item's `id` is always `"new-session"` (stable ID for SwiftUI and matchResults lookup).
- The `.newSession` case does not participate in frecency sorting (it's always pinned to index 0). It has no `frecencyKey`.

Computed properties for the `.newSession` case:
- `displayName`: "New session: \(name)" or "New session + create directory: \(path)" or "New SSH session: \(hostname)"
- `subtitle`: directory path with " (⌘ for ~)" hint for non-SSH modes, hostname for SSH mode
- `id`: `"new-session"`

### Three Modes

Based on the query text, "New" resolves differently:

1. **Plain text** (e.g. "proj") — create a new session named "proj" in the active pane's current working directory (obtained from the active session's active pane via `SessionStore`). Fallback chain if active pane CWD is nil: session directory → home directory.
2. **Path-like** (query contains `/` or starts with `~`) — create a new session in the resolved path. Name = basename of path.
   - Tilde expanded via `NSString.expandingTildeInPath`.
   - If the resolved path points to a file (not a directory), don't show "New".
   - If the directory exists: show "New session: name" with subtitle showing the path.
   - If the directory doesn't exist but the parent directory exists: show "New session + create directory: path".
   - If the parent doesn't exist: don't show the "New" option (likely a typo).
3. **SSH-like** (query starts with "ssh " with at least one non-empty character after the space) — the SSH hostname is extracted by taking everything after the first space and trimming whitespace (so "ssh  myhost" yields "myhost"). Creates a new SSH session to that hostname. Uses `MisttyConfig.ssh.resolveCommand(for:)` to resolve the SSH command, falling back to the default command. The resolved command is stored in `sshCommand`.

### Position and Selection

- "New" always appears at the **top** of the filtered list (index 0) when the query is non-empty.
- **Not selected by default** — `selectedIndex` starts at 1 (first real match) when other results exist below "New".
- **Becomes default-selected** (index 0) when it's the only remaining item (all real matches filtered out).
- Not shown when query is empty.

### Cmd Modifier

When the user confirms selection while holding Cmd, the directory is overridden to the home directory (`~`). The "New" row subtitle hints at this: e.g. "in ~/Developer/proj (Cmd for ~)".

### Display

- Prefix with SF Symbol `plus.circle` to distinguish from regular results.
- Visually distinct (slightly different styling or separator) from the match results below.

## Tab/Right Arrow Completion

### Keyboard Interception

The existing `FocusableTextField` (NSTextField wrapper) needs its coordinator to override `control(_:textView:doCommandBy:)` to intercept Tab and Right Arrow before NSTextField consumes them.

- **Right Arrow** triggers completion **only when the cursor is at the end of the text field**. Otherwise it performs normal cursor movement within the text.
- **Tab** always triggers completion (NSTextField would normally move focus; we override this).
- **When the "New" item is selected**: Tab/Right Arrow are no-ops (there's nothing to complete from).

### Completion Behavior

When a result item (not "New") is selected and completion triggers:

- The query text field is replaced with the selected item's path/identifier:
  - Directory → full path (e.g. `~/Developer/workspace`)
  - Running session → session name
  - SSH host → alias
- Cursor placed at end of inserted text.
- Filter re-runs with the new query.
- This allows the user to Tab-complete a zoxide hit like `~/Developer/workspace`, then append `/newproject` to create a subdirectory session via the "New" option.

After Tab-completing a path and typing more, the "New" option updates to reflect the full composed path (e.g. "New session + create directory: ~/Developer/workspace/newproject"). This is expected behavior — "New" is still shown even when the completed path exactly matches an existing result.

## Changes to SessionManagerViewModel

### Updated Filter Flow (`applyFilter()`)

1. **Empty query** (including whitespace-only) — `filteredItems = allItems` sorted by frecency, no "New" option, `selectedIndex = 0`.
2. **Non-empty query:**
   - Split query by spaces into tokens, discard empty tokens.
   - For each item, run `FuzzyMatcher.match()` per token against the item's matchable fields (matching each field separately, taking the best score per field).
   - Keep items where all tokens match (AND logic).
   - Store the `ItemMatchResult` (best match + which field) per item in `matchResults`.
   - Sort by: match score descending, frecency as tiebreaker for equal scores.
   - Prepend "New" option (if applicable per path/SSH/plain-text resolution rules).
   - Set `selectedIndex = 1` if real matches exist below "New", otherwise `selectedIndex = 0`.

Note on scoring for multi-field items: basename matches will naturally score higher than full-path matches due to the "shorter target bonus." This is intentional — a basename match is a more relevant hit.

### New Stored State

- `matchResults: [SessionManagerItem.ID: ItemMatchResult]` — maps item IDs to their match score and per-field matched indices for highlighting.

### Updated `confirmSelection(modifierFlags:)`

- Accepts `NSEvent.ModifierFlags` to detect Cmd held.
- For `.newSession` items:
  - If `createDirectory` is true, create the directory first (check existence again at confirmation time to avoid races).
  - If `sshCommand` is non-nil, create session with that SSH exec command.
  - If Cmd held, override directory to home.
  - Create session with resolved name and directory.
- Records frecency for the resulting `"session:<name>"` key.

## View Changes

### Match Highlighting

Each item row renders its display name and subtitle with matched characters highlighted in the accent color. Uses `displayNameIndices` and `subtitleIndices` from `ItemMatchResult` to highlight each field independently. Both fields can have highlights simultaneously (e.g. when different tokens match different fields).

### "New" Row Styling

- SF Symbol `plus.circle` prefix.
- Subtitle shows directory context and Cmd hint.
- Standard accent highlight when selected.

### Modifier Flag Passing

- On Enter keypress, pass `NSEvent.modifierFlags` to `confirmSelection(modifierFlags:)`.
- On click, use `NSEvent.modifierFlags` (the current modifier state at the time of the click) since SwiftUI's `onTapGesture` doesn't provide modifier flags directly. Read `NSApp.currentEvent?.modifierFlags` at the point of the tap handler.

## Edge Cases

- **Empty query / whitespace-only:** All items shown sorted by frecency, no "New" option, `selectedIndex = 0`.
- **Query matches nothing:** Only "New" visible (if applicable), automatically selected.
- **Tilde expansion:** `~` and `~/...` resolved via `NSString.expandingTildeInPath`.
- **Path detection:** A query is "path-like" if it contains `/` or starts with `~`.
- **Path points to a file:** Don't show "New" (only directories are valid session targets).
- **"ssh " with no hostname:** Don't show SSH "New" option (need at least one non-empty character after "ssh ").
- **SSH host with nil hostname:** Match against alias only, skip hostname field.
- **Current session:** Still hidden from results (no change).
- **Frecency recording:** When "New" creates a session, frecency is recorded for the new session key.
- **Zoxide + path queries:** Zoxide directories still appear in results when they match the path query. "New" is the escape hatch to create a fresh session instead.
- **Symlinks:** Paths are resolved via `URL.standardizedFileURL` for consistency with the existing `load()` logic.
- **Directory created between filter and confirm:** `confirmSelection` re-checks directory existence before attempting creation to avoid errors.

## Files to Change

| File | Change |
|------|--------|
| New: `Mistty/Services/FuzzyMatcher.swift` | Fuzzy matching algorithm |
| `Mistty/Views/SessionManager/SessionManagerViewModel.swift` | Filter logic, "New" item case, match results storage, multi-token AND, SSH boost, Tab completion, confirmSelection with modifiers |
| `Mistty/Views/SessionManager/SessionManagerView.swift` | Match highlighting, "New" row styling, Tab/Right Arrow handling, modifier flag passing |
| `Mistty/Views/SessionManager/FocusableTextField.swift` | Override `control(_:textView:doCommandBy:)` for Tab/Right Arrow interception |
| `MisttyTests/Services/FuzzyMatcherTests.swift` | Fuzzy matcher unit tests |
| `MisttyTests/Views/SessionManagerViewModelTests.swift` | Updated filter/selection tests |
