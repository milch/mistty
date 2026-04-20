# Tab bar visibility override — fix stale pinning

Date: 2026-04-19
Status: Design

## Problem

After adding the Cmd+Shift+B tab-bar override (commit `ee059b5`), users
report that `tab_bar_mode` values like `when_sidebar_hidden_and_multiple_tabs`
stop working. Root cause: `TabBarVisibilityOverride` is persisted in
`@AppStorage("tabBarOverride")`. Once the shortcut is pressed, `toggled()`
flips between `.hidden` and `.visible` forever — it never returns to `.auto`.
So the configured `tab_bar_mode` rule is effectively bypassed for the rest
of that machine's lifetime.

The user's example: `tab_bar_mode = "when_multiple_tabs"`, 1 tab, bar hidden.
User presses Cmd+Shift+B → bar shows (override=`.visible`). User opens a
second tab, then closes it → bar should be hidden again. Today it stays
shown because `.visible` is pinned.

## Non-goals

- No per-mode UI. The shortcut still does one thing: flip the current
  visibility.
- No "never show the override" escape hatch in config. If someone really
  doesn't want the shortcut, they'll rebind it when we ship configurable
  shortcuts (separate PLAN item).
- No reset on app relaunch from durable storage — the override simply
  isn't durable anymore (see below).

## Design rule

> **An override is absorbed back into `.auto` the moment the configured rule
> produces the same answer as the override.**

This is the only new rule. It handles the 2-tabs case and, in combination
with the toggle change below, every other mode.

Walkthrough per mode:

| Mode | configured flips? | How override clears |
| --- | --- | --- |
| `always` | never | second press cycles override back to `.auto` |
| `never` | never | second press cycles override back to `.auto` |
| `when_multiple_tabs` | tabCount crossing 1↔2+ | auto-resolves on natural state change |
| `when_sidebar_hidden` | sidebar toggle | auto-resolves |
| `when_sidebar_hidden_and_multiple_tabs` | sidebar OR tabCount | auto-resolves |

## Changes

### 1. Override state becomes per-window `@State`

Remove `@AppStorage("tabBarOverride")` from both `ContentView.swift` and
`MisttyApp.swift`. ContentView owns the state:

```swift
@State private var tabBarOverride: TabBarVisibilityOverride = .auto
```

The "Toggle Tab Bar" menu item in `MisttyApp.swift` can no longer read
`config`/`sidebarVisible` to compute the toggled value — those live in
ContentView. Instead: post a new `.misttyToggleTabBar` notification.
ContentView receives it and runs the toggle with the full context
(configured value) in scope.

This makes the override:
- Truly ephemeral (app relaunch → `.auto`)
- Per-window in storage (each ContentView has its own `@State`; in practice
  the shared `SessionStore` keeps them in sync — see Risks)
- Decoupled from UserDefaults (no stale state from last week's session)

### 2. `toggled` returns `.auto` from non-auto

In `MisttyConfig.swift`:

```swift
func toggled(configuredShow: Bool) -> TabBarVisibilityOverride {
  switch self {
  case .auto:
    return configuredShow ? .hidden : .visible
  case .hidden, .visible:
    return .auto
  }
}
```

Rationale: a user who has already overridden and presses again wants to
stop overriding. Returning to the other non-auto value just perpetuates
the override with no path back to config-driven behavior — exactly the
bug we're fixing. This also covers `always`/`never`, which never
auto-resolve (configured never flips).

### 3. Auto-resolve on state change

Drive the reset off `.onChange` rather than a render-time side effect.
The override only needs to be re-evaluated when one of its inputs (sidebar
visibility, active session's tab count) changes.

```swift
.onChange(of: sidebarVisible) { _, _ in resolveOverrideIfMatched() }
.onChange(of: store.activeSession?.tabs.count) { _, _ in
  resolveOverrideIfMatched()
}

private func resolveOverrideIfMatched() {
  guard tabBarOverride != .auto else { return }
  let tabCount = store.activeSession?.tabs.count ?? 1
  let configured = config.ui.tabBarMode.shouldShow(
    sidebarVisible: sidebarVisible, tabCount: tabCount)
  if tabBarOverride.effectiveShow(configuredShow: configured) == configured {
    tabBarOverride = .auto
  }
}
```

`store.activeSession` is `@Observable` (see `SessionStore.swift`), and
`MisttySession.tabs` is an `@Observable` array, so the `.onChange`
expression is stable under SwiftUI's dependency tracking.

`shouldShowTabBar` stays trivial:

```swift
private func shouldShowTabBar(tabCount: Int) -> Bool {
  let configured = config.ui.tabBarMode.shouldShow(
    sidebarVisible: sidebarVisible, tabCount: tabCount)
  return tabBarOverride.effectiveShow(configuredShow: configured)
}
```

### 4. Notification plumbing

Add `Notification.Name.misttyToggleTabBar` in `MisttyApp.swift`.
The "Toggle Tab Bar" button body shrinks to:

```swift
Button("Toggle Tab Bar") {
  NotificationCenter.default.post(name: .misttyToggleTabBar, object: nil)
}
.keyboardShortcut("b", modifiers: [.command, .shift])
```

ContentView gets a receiver:

```swift
.onReceive(NotificationCenter.default.publisher(for: .misttyToggleTabBar)) { _ in
  let tabCount = store.activeSession?.tabs.count ?? 1
  let configured = config.ui.tabBarMode.shouldShow(
    sidebarVisible: sidebarVisible, tabCount: tabCount)
  withAnimation(.easeInOut(duration: 0.15)) {
    tabBarOverride = tabBarOverride.toggled(configuredShow: configured)
  }
}
```

## Tests

Update `MisttyTests/Config/UIConfigTests.swift`:

- Replace `test_toggle_fromHidden_goesVisible` with
  `test_toggle_fromHidden_goesAuto`: both configured values produce `.auto`.
- Replace `test_toggle_fromVisible_goesHidden` with
  `test_toggle_fromVisible_goesAuto`: both configured values produce `.auto`.
- Keep `test_toggle_fromAuto_flipsConfiguredDefault` unchanged.

No new unit tests for the auto-resolve behavior — it's a one-liner in a
view and the logic is trivial. Manual verification via the app covers it.

No snapshot test changes needed; the matrix in `ChromePolishSnapshotTests`
already exercises the five modes with `override == .auto` implicit, and
the new behavior only differs when the override is active.

## Migration

The `tabBarOverride` UserDefaults key is simply orphaned. No migration
code; stale values have no effect after this change because nothing reads
them. Leaving them in UserDefaults costs a few bytes per user.

## Risks

- **Notification fans out to every ContentView**: in multi-window mode,
  every window's ContentView receives `.misttyToggleTabBar` and toggles
  its own `@State`. Because the shared `SessionStore.activeSession` means
  all windows see the same sidebar + tab count, the `configured` input to
  `toggled` is identical in each, so the resulting override value stays
  in sync across windows. Net effect: still looks "global," just
  ephemeral. Matches the pattern used by every other notification-driven
  command in this file (e.g. `.misttyNewTab`).
- **`.onChange` doesn't fire on initial render**: the override starts at
  `.auto`, so there's nothing to resolve. The handlers only run on
  subsequent changes, which is exactly what we want.
- **Session switches trigger auto-resolve**: the `.onChange(of: store.activeSession?.tabs.count)` handler also fires when the user switches sessions (because the active session's tab count changes). The resolver then evaluates the configured rule against the *new* session's tab count and may clear an override that was set on the previous session. This is an inherent property of the per-window (not per-session) state scope; a cross-session override would need a different design.
