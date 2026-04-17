# Chrome Polish — UI Improvements

Status: design
Date: 2026-04-16

## Summary

A coherent pass over Mistty's native chrome: hide the macOS title bar, tighten the tab bar, collapse it when a session has at most one tab, animate sidebar show/hide, upgrade sidebar row text to reflect active-pane context, add process icons via a bundled Nerd Font, and replace the session manager's Unicode row icons with SFSymbols. Grouped into one spec because the surfaces interact (title bar visibility affects tab bar layout; sidebar label model feeds the same data surface as tab bar titles; icon logic is shared across sidebar and future features).

## Goals

- Reduce visual weight of window chrome so the terminal surface dominates the window.
- Keep sidebar information-dense but scannable — process at a glance, location at a glance.
- Ship the changes as independent, reviewable chunks (one shared infra change per chunk at most).
- No user-visible breaking changes to keybindings, session manager flow, or IPC surface.

## Non-goals (deferred)

- Per-tab process icon in the tab bar itself (only sidebar + session manager get icons this pass).
- User-configurable icon map. The mapping table is a static Swift dictionary; configurability is a future feature.
- Animation of tab reordering or pane layout transitions — unrelated.
- Session manager icon customization or theming.
- Nerd Font for general terminal rendering — the bundled font is for UI chrome only, not the terminal surface.

## Phased rollout

Each phase is an independently mergeable chunk. Later phases may depend on earlier ones; dependencies noted.

1. **Window chrome** — hide macOS title bar; inset main content under floating traffic lights.
2. **Tab bar restyle + auto-hide** — subtle pill style at 28px, hidden when `tabs.count <= 1`, animated transitions. Depends on #1 for layout.
3. **Sidebar animation** — slide in/out with eased animation; pure cosmetic, no model changes.
4. **Session label model** — introduce `customName` field and `sidebarLabel` computed property; drives the sidebar's session row text.
5. **Process icons** — bundle Symbols-only Nerd Font, register at launch, add `ProcessIcon.glyph(for:)`, render in sidebar rows.
6. **Session manager SFSymbols** — replace Unicode prefix icons with `Image(systemName:)` in an icon column.

Phases 3–6 are mutually independent and could reorder.

## Phase 1: Window chrome

### Decision

Use `.windowStyle(.hiddenTitleBar)` on the app's `WindowGroup`. Traffic lights remain floating at top-left at their standard macOS offset.

### Changes

- `MisttyApp.body.WindowGroup { ... }.windowStyle(.hiddenTitleBar)`.
- The topmost strip (y ∈ [0, 28)) is a drag region; traffic lights float at their standard offset inside it.
- Four layout cases, based on `sidebarVisible` and `session.tabs.count > 1`:

  | Sidebar | Tab bar | Leading inset (lights clearance) | Top inset (lights clearance) |
  |---|---|---|---|
  | visible | visible | sidebar takes leading 220pt; tab bar starts after divider | tab bar occupies the 28pt strip |
  | visible | hidden | sidebar takes leading 220pt | first row of main column gets `.padding(.top, 28)` |
  | hidden  | visible | tab bar gets `.padding(.leading, 72)` | tab bar occupies the 28pt strip |
  | hidden  | hidden  | main column gets `.padding(.leading, 72)` | main column gets `.padding(.top, 28)` |

- When the sidebar is visible, its first row gets `.padding(.top, 28)` so content clears the floating lights. The `Divider()` between sidebar and main content extends to `y=0` (full window height).
- No custom `NSWindow` delegate, no custom traffic-light repositioning.

### Drag region

`.hiddenTitleBar` keeps the top area draggable by default. The 28px top strip where the tab bar (or padding) sits is a valid drag region. SwiftUI buttons and the tab `HStack` children register as hit-testable interactive views automatically; no explicit `WindowDragHandler` needed.

### Rationale

Floating traffic lights are the minimum-risk approach and match Ghostty's own behavior. Custom draggable tab bar (Arc-style) would duplicate Ghostty work for marginal visual gain.

## Phase 2: Tab bar — subtle pill + auto-hide

### Style (applied to `TabBarView` / `TabBarItem`)

| Property | Value |
|---|---|
| Bar height | `28` |
| Bar horizontal padding | `6` |
| Tab padding | `.horizontal 10`, `.vertical 4` |
| Tab corner radius | `5` |
| Tab font | `.system(size: 11)` |
| Inactive tab color | `.secondary` |
| Active tab color | `.primary` |
| Active tab background | `Color.primary.opacity(0.08)` (adapts to light/dark) |
| `+` button size | `24 x 24`, `.plain` style |
| Close `x` visibility | Only on active tab (current behavior retained) |
| Bell dot | Unchanged (6pt orange circle) |

### Auto-hide

```swift
if session.tabs.count > 1 {
  TabBarView(session: session)
    .transition(.asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .move(edge: .top).combined(with: .opacity)
    ))
  Divider().transition(.opacity)
}
```

Changes to `session.tabs.count` wrapped in `withAnimation(.easeInOut(duration: 0.15))` at the call site (e.g., `addTab`, `closeTab` in `MisttySession`). Alternative: `.animation(.easeInOut(duration: 0.15), value: session.tabs.count)` on the outer container; verify during implementation which yields cleaner transitions.

### Layout when hidden

With the tab bar hidden and the sidebar also hidden, the main content column gets `.padding(.top, 28)` so the first terminal row clears the floating traffic lights. With the tab bar visible, it occupies that same 28px strip and the padding is not applied.

### Rationale

Subtle-pill at 28px is the style the user picked from a mocked comparison (see brainstorm session). Auto-hide matches the user's stated preference of reducing chrome when unused.

## Phase 3: Sidebar slide animation

### Implementation

- `ContentView.mainContent` wraps the conditional sidebar in a container that uses `.transition(.move(edge: .leading))`.
- The `sidebarVisible.toggle()` in `MisttyApp`'s `Toggle Sidebar` command wraps in `withAnimation(.easeInOut(duration: 0.18))`.
- The divider between sidebar and main content is part of the same conditional branch so it transitions together.
- The drag handle for resize does not animate (it moves with the sidebar as one unit).

### Rationale

180ms ease-in-out is a comfortable default matching macOS system animations; short enough not to feel sluggish, long enough to read as intentional rather than abrupt.

## Phase 4: Session label model

### New state

Add to `MisttySession`:

```swift
var customName: String?
```

Populated by `SessionManagerViewModel` at session creation when the user typed a non-path, non-SSH query. The existing `name` field remains the canonical identifier for session manager display, frecency, and IPC.

### Sidebar label computation

New computed property on `MisttySession`:

```swift
var sidebarLabel: String {
  if let customName { return customName }
  if let sshCommand, let host = Self.parseSSHHost(sshCommand) { return host }
  if let cwd = activeTab?.activePane?.directory {
    return cwd.lastPathComponent
  }
  return directory.lastPathComponent
}
```

SSH host parser: extract the last non-flag token of the command and split on `@` to take the post-`@` portion, else the token itself.

**Note on CWD liveness:** `MisttyPane.directory` is populated at pane construction and not updated when the shell changes directory. The "active pane CWD basename" branch therefore reflects the initial working directory, not the live `pwd`. Wiring OSC-7 / shell integration to update `pane.directory` on `cd` is tracked as a follow-up and is out of scope for this spec.

Tab row label (sidebar): **no change**. Continues to use `tab.displayTitle` (which honors `customTitle` then `title`, where `title` is the process title pushed by ghostty).

### Migration

Existing sessions at launch have `customName == nil`. Until renamed, they fall through to the SSH/CWD/directory basename chain. This is intended: user-visible labels in the sidebar shift immediately to active-pane context.

### Session manager view

`SessionManagerItem.runningSession(s)` displays `s.name` (unchanged). The session manager keeps identity-style naming; only the sidebar picks up dynamic CWD/host labels.

### Rationale

An explicit `customName` field avoids heuristic-based detection ("is this name a path? does it match the default?") and cleanly separates identity (`name`) from display (`sidebarLabel`). `customTitle` on `MisttyTab` is a precedent for this pattern.

## Phase 5: Process icons via bundled Nerd Font

### Font bundling

- Add `SymbolsNerdFontMono-Regular.ttf` (~200KB) under `Mistty/Resources/Fonts/`. (Source: nerdfonts.com "Symbols Only" release.)
- Register at `MisttyApp.init()`:

```swift
if let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") {
  CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
```

- No `Info.plist` `ATSApplicationFontsPath` entry — process-scoped registration is sufficient and avoids leaking the font system-wide.

### Mapping

New file: `Mistty/Support/ProcessIcon.swift`.

```swift
enum ProcessIcon {
  static let fontName = "SymbolsNerdFontMono"

  static func glyph(forProcessTitle title: String?) -> Character {
    guard let name = normalize(title) else { return fallback }
    return map[name] ?? fallback
  }

  static func glyph(forSession session: MisttySession) -> Character {
    if session.sshCommand != nil { return sshGlyph }
    return glyph(forProcessTitle: session.activeTab?.activePane?.processTitle)
  }

  private static let fallback: Character = "\u{f489}" // terminal
  private static let sshGlyph: Character = "\u{f817}" // network

  private static let map: [String: Character] = [
    "nvim": "\u{e7c5}", "vim": "\u{e7c5}",
    "claude": "\u{f0e7}",  // spark
    "zsh": "\u{f489}", "bash": "\u{f489}", "fish": "\u{f489}", "sh": "\u{f489}",
    "node": "\u{e718}", "npm": "\u{e71e}", "pnpm": "\u{e718}", "yarn": "\u{e718}",
    "python": "\u{e73c}", "python3": "\u{e73c}", "ipython": "\u{e73c}",
    "ruby": "\u{e739}", "irb": "\u{e739}",
    "go": "\u{e627}", "cargo": "\u{e7a8}", "rustc": "\u{e7a8}",
    "docker": "\u{f308}",
    "git": "\u{f1d3}", "lazygit": "\u{f1d3}",
    "ssh": "\u{f817}", "mosh": "\u{f817}",
    "tmux": "\u{ebc8}",
    "htop": "\u{f2db}", "btop": "\u{f2db}",
    "mysql": "\u{e704}", "psql": "\u{e76e}",
    "make": "\u{e673}",
  ]

  private static func normalize(_ title: String?) -> String? {
    guard let title = title?.lowercased() else { return nil }
    let firstToken = title.split(separator: " ").first.map(String.init) ?? title
    return firstToken.isEmpty ? nil : firstToken
  }
}
```

Glyph codepoints cited above are illustrative; the implementation will use the canonical values from the Nerd Font v3 cheat sheet (`nvim` → `nf-custom-neovim`, etc.). Chosen to mirror nvim-web-devicons where a mapping exists.

### Rendering

Sidebar row — tab level (inside `SessionRowView`'s `ForEach`):

```swift
Text(String(ProcessIcon.glyph(forProcessTitle: tab.activePane?.processTitle)))
  .font(.custom(ProcessIcon.fontName, size: 12))
  .foregroundStyle(.secondary)
  .frame(width: 14, alignment: .center)
```

Sidebar row — session level (inside `SessionRowView`'s `DisclosureGroup` label):

```swift
Text(String(ProcessIcon.glyph(forSession: session)))
  .font(.custom(ProcessIcon.fontName, size: 12))
  .foregroundStyle(.secondary)
  .frame(width: 14, alignment: .center)
```

### Rationale

Nerd Font glyphs track nvim-web-devicons conventions, which the user prefers. Bundling the font avoids depending on the user's terminal font and eliminates missing-glyph regressions.

## Phase 6: Session manager SFSymbols

### Changes in `SessionManagerView`

Replace the Unicode-prefix emission in `SessionManagerItem.displayName` and introduce a dedicated icon column in the row layout.

```swift
HStack(spacing: 8) {
  Image(systemName: item.symbolName)
    .font(.system(size: 13))
    .frame(width: 16, height: 16)
    .foregroundStyle(index == vm.selectedIndex ? Color.accentColor : .secondary)
  VStack(alignment: .leading, spacing: 2) { /* existing title + subtitle */ }
  Spacer()
}
```

New property on `SessionManagerItem`:

```swift
var symbolName: String {
  switch self {
  case .runningSession: return "terminal.fill"
  case .directory: return "folder"
  case .sshHost: return "network"
  case .newSession: return "plus.circle"
  }
}
```

`displayName` drops the Unicode prefix (`▶ `, `⌁ `) now that the icon column carries that information.

### Rationale

SFSymbols are native, scale with the system, respect accessibility, and align visually with macOS conventions.

## Shared concerns

### Font registration lifecycle

`CTFontManagerRegisterFontsForURL` is called once per process launch, in `MisttyApp.init()`. It is idempotent within a process and does not need unregistration on app exit.

### Testing

- **Phase 1**: snapshot test not practical for window-level behavior. Manual verification: traffic lights visible and functional; dragging window by top strip works; resizing works.
- **Phase 2**: unit test the `session.tabs.count <= 1` visibility logic (show the tab bar is absent from the view hierarchy in that case, via a SwiftUI inspection helper or by exposing a view-model-level boolean `isTabBarVisible`).
- **Phase 3**: manual verification; no new tests.
- **Phase 4**: unit tests for `MisttySession.sidebarLabel` covering the four priority branches (custom name, SSH, active pane CWD, fallback directory). Unit tests for SSH host parser.
- **Phase 5**: unit tests for `ProcessIcon.glyph(forProcessTitle:)` — nil input, known process, known process with arg suffix, unknown process, empty string. Manual verification of font rendering (font loaded, glyphs render).
- **Phase 6**: verify all four item types render the right SFSymbol. Manual verification of icon sizing and color states.

### Performance

- `sidebarLabel` recomputation is cheap (property access + optional string parse). Fires on every observable change to `activePane` or `directory`, but both are low-frequency.
- Font registration is a single call at launch.
- Icon glyph lookup is a dictionary hit per row; irrelevant.

## Open questions

- Exact Nerd Font codepoints are finalized during implementation against the Nerd Font v3 cheat sheet. The mapping shape in this spec is authoritative; the specific `\u{...}` values are illustrative.
- Whether to animate the sidebar's content reflow (the `HStack` width change) is left to the SwiftUI framework default under `withAnimation`. If it looks janky during implementation, explicitly animate `sidebarWidth` instead of relying on implicit animation.

## Not in scope

- Tab bar dragging to reorder.
- Drag-and-drop tabs between sessions.
- User-configurable color scheme for tab bar or sidebar.
- Per-user icon map overrides.
- macOS window restoration integration for `customName`.
