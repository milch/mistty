# Tab Bar Override Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the stale `tab_bar_mode` bug by making `TabBarVisibilityOverride` ephemeral, letting two presses cycle back to `.auto`, and auto-resolving the override when the configured rule catches up.

**Architecture:** Move override state from `@AppStorage` to per-ContentView `@State`. Change `toggled()` so `non-auto → .auto`. Drive a state-change auto-resolve off `.onChange(of: sidebarVisible)` and `.onChange(of: activeSession?.tabs.count)`. Route the menu shortcut through a new `.misttyToggleTabBar` notification.

**Tech Stack:** Swift / SwiftUI (macOS 14+), XCTest.

**Spec:** `docs/superpowers/specs/2026-04-19-tab-bar-override-design.md`

---

## File Structure

| File | Role |
| --- | --- |
| `Mistty/Config/MisttyConfig.swift` | `TabBarVisibilityOverride.toggled` gets the `non-auto → .auto` rule. |
| `MisttyTests/Config/UIConfigTests.swift` | Replace the two `toggle_from{Hidden,Visible}` tests. |
| `Mistty/App/MisttyApp.swift` | Drop `@AppStorage("tabBarOverride")`; replace inline button logic with a `.misttyToggleTabBar` notification post; declare the new `Notification.Name`. |
| `Mistty/App/ContentView.swift` | Drop `@AppStorage("tabBarOverride")`, add `@State tabBarOverride`, an `.onReceive` handler for the toggle notification, and `.onChange` handlers that call a new `resolveOverrideIfMatched()` helper. `shouldShowTabBar` reads the `@State` instead. |

No new files.

---

## Task 1: Update `toggled` logic (pure Swift, TDD)

**Files:**
- Modify: `Mistty/Config/MisttyConfig.swift:73-76`
- Modify: `MisttyTests/Config/UIConfigTests.swift:93-101`

- [ ] **Step 1: Rewrite the two failing test cases**

Open `MisttyTests/Config/UIConfigTests.swift`. Replace the existing
`test_toggle_fromHidden_goesVisible` and `test_toggle_fromVisible_goesHidden`
(lines 93-101) with:

```swift
  func test_toggle_fromHidden_goesAuto() {
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: true), .auto)
    XCTAssertEqual(TabBarVisibilityOverride.hidden.toggled(configuredShow: false), .auto)
  }

  func test_toggle_fromVisible_goesAuto() {
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: true), .auto)
    XCTAssertEqual(TabBarVisibilityOverride.visible.toggled(configuredShow: false), .auto)
  }
```

Leave `test_toggle_fromAuto_flipsConfiguredDefault` (lines 86-91) unchanged.

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
```

Expected: two failures in `UIConfigTests`:

```
test_toggle_fromHidden_goesAuto : XCTAssertEqual failed: (visible) is not equal to (auto)
test_toggle_fromVisible_goesAuto : XCTAssertEqual failed: (hidden) is not equal to (auto)
```

(Remaining tests should still pass.)

- [ ] **Step 3: Update `toggled` to make the tests pass**

Open `Mistty/Config/MisttyConfig.swift`. Replace the body of
`TabBarVisibilityOverride.toggled(configuredShow:)` (lines 73-76) with:

```swift
  /// Next override after a user toggle:
  /// - From `.auto`, flip to the opposite of whatever the config rule shows.
  /// - From `.hidden`/`.visible`, return to `.auto` so the user can pop the
  ///   override without having to know its current direction.
  func toggled(configuredShow: Bool) -> TabBarVisibilityOverride {
    switch self {
    case .auto:
      return configuredShow ? .hidden : .visible
    case .hidden, .visible:
      return .auto
    }
  }
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "Test Suite.*UIConfigTests|Executed.*tests" /tmp/mistty-test.log
```

Expected: all `UIConfigTests` pass, overall suite passes.

- [ ] **Step 5: Commit**

```bash
git add Mistty/Config/MisttyConfig.swift MisttyTests/Config/UIConfigTests.swift
git commit -m "$(cat <<'EOF'
fix(ui): tab-bar override toggle cycles back to auto

Previously pressing Cmd+Shift+B flipped between .hidden and .visible
with no path back to .auto, which pinned tab_bar_mode out of effect.
Two presses now always restores config-driven behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Move override state to `@State` + notification plumbing

**Files:**
- Modify: `Mistty/App/MisttyApp.swift:11` (remove `@AppStorage`), `:64-73` (button body), `:275-293` (add notification name)
- Modify: `Mistty/App/ContentView.swift:10` (replace `@AppStorage` with `@State`), `:108-110` area (add `.onReceive`), `:277-282` (update `shouldShowTabBar`)

- [ ] **Step 1: Add the new notification name**

Open `Mistty/App/MisttyApp.swift`. In the `Notification.Name` extension at
the bottom of the file (starts at line 275), add a new line alphabetically
near the other tab-related names. After the `misttyCloseTab` line, add:

```swift
  static let misttyToggleTabBar = Notification.Name("misttyToggleTabBar")
```

- [ ] **Step 2: Replace the "Toggle Tab Bar" button body**

In `Mistty/App/MisttyApp.swift`, find the button at lines 64-73:

```swift
        Button("Toggle Tab Bar") {
          let tabCount = store.activeSession?.tabs.count ?? 1
          let configured = config.ui.tabBarMode.shouldShow(
            sidebarVisible: sidebarVisible, tabCount: tabCount)
          let current = TabBarVisibilityOverride(rawValue: tabBarOverrideRaw) ?? .auto
          withAnimation(.easeInOut(duration: 0.15)) {
            tabBarOverrideRaw = current.toggled(configuredShow: configured).rawValue
          }
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
```

Replace with:

```swift
        Button("Toggle Tab Bar") {
          NotificationCenter.default.post(name: .misttyToggleTabBar, object: nil)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
```

- [ ] **Step 3: Remove the now-unused `@AppStorage` from `MisttyApp`**

In `Mistty/App/MisttyApp.swift`, delete line 11:

```swift
  @AppStorage("tabBarOverride") var tabBarOverrideRaw = TabBarVisibilityOverride.auto.rawValue
```

- [ ] **Step 4: Replace `@AppStorage` with `@State` in ContentView**

In `Mistty/App/ContentView.swift`, replace line 10:

```swift
  @AppStorage("tabBarOverride") var tabBarOverrideRaw = TabBarVisibilityOverride.auto.rawValue
```

with:

```swift
  @State private var tabBarOverride: TabBarVisibilityOverride = .auto
```

- [ ] **Step 5: Update `shouldShowTabBar` to read the new `@State`**

In `Mistty/App/ContentView.swift`, replace `shouldShowTabBar` (lines 277-282):

```swift
  private func shouldShowTabBar(tabCount: Int) -> Bool {
    let configured = config.ui.tabBarMode.shouldShow(
      sidebarVisible: sidebarVisible, tabCount: tabCount)
    let override = TabBarVisibilityOverride(rawValue: tabBarOverrideRaw) ?? .auto
    return override.effectiveShow(configuredShow: configured)
  }
```

with:

```swift
  private func shouldShowTabBar(tabCount: Int) -> Bool {
    let configured = config.ui.tabBarMode.shouldShow(
      sidebarVisible: sidebarVisible, tabCount: tabCount)
    return tabBarOverride.effectiveShow(configuredShow: configured)
  }
```

- [ ] **Step 6: Wire up the toggle notification receiver**

In `Mistty/App/ContentView.swift`, in `contentWithOverlays` (the view
modifier chain starting at line 85), add a new `.onReceive` at the end of
the chain, after the `.onReceive` for `.misttySessionManager` (line 108-110):

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

- [ ] **Step 7: Build and verify compilation**

```bash
just build 2>&1 | tee /tmp/mistty-build.log
```

Expected: build succeeds with no errors.

If there's a warning about `sidebarVisible` / `tabBarOverrideRaw` being
unused elsewhere, check that every reference to `tabBarOverrideRaw` in
both files has been replaced or removed.

```bash
grep -rn "tabBarOverrideRaw" Mistty/ MisttyTests/
```

Expected: no results.

- [ ] **Step 8: Run tests**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "Executed|FAIL|PASS" /tmp/mistty-test.log | tail -20
```

Expected: all tests pass.

- [ ] **Step 9: Manual smoke test**

```bash
just run
```

In the running app:

1. Open with `tab_bar_mode = "when_multiple_tabs"` in `~/.config/mistty/config.toml`. Confirm: 1 tab → bar hidden, 2 tabs → bar shown.
2. With 1 tab, press Cmd+Shift+B → bar shows.
3. Press Cmd+Shift+B again → bar hides (override back to `.auto`, configured=hidden).
4. Quit the app. Relaunch. 1 tab → bar hidden (no stale override from AppStorage).

If all four steps behave correctly, override plumbing is working. Note:
the "close tab after opening second" auto-resolve is Task 3.

- [ ] **Step 10: Commit**

```bash
git add Mistty/App/MisttyApp.swift Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
refactor(ui): tab-bar override becomes per-window @State

Drops the @AppStorage("tabBarOverride") persistence in favor of
ephemeral per-ContentView @State, routed through a new
.misttyToggleTabBar notification from the menu button. Stale
overrides from previous sessions no longer pin tab_bar_mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Auto-resolve override when configured catches up

**Files:**
- Modify: `Mistty/App/ContentView.swift` (add `resolveOverrideIfMatched()` + two `.onChange` handlers)

- [ ] **Step 1: Add the resolver helper**

In `Mistty/App/ContentView.swift`, add a new private method right after
`shouldShowTabBar` (near line 282):

```swift
  /// Clear the override when the configured rule would produce the same
  /// visibility we're already forcing — i.e. the override has become
  /// redundant. Called from `.onChange` on its inputs.
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

- [ ] **Step 2: Wire the two `.onChange` triggers**

In `Mistty/App/ContentView.swift`, in `contentWithOverlays`, add both
`.onChange` calls just after the new `.onReceive` for `.misttyToggleTabBar`
(added in Task 2 Step 6):

```swift
      .onChange(of: sidebarVisible) { _, _ in
        resolveOverrideIfMatched()
      }
      .onChange(of: store.activeSession?.tabs.count) { _, _ in
        resolveOverrideIfMatched()
      }
```

- [ ] **Step 3: Build and verify compilation**

```bash
just build 2>&1 | tee /tmp/mistty-build.log
```

Expected: build succeeds. If SwiftUI complains about the `.onChange(of:)`
two-parameter closure form, this project is on macOS 14+ per
`Package.swift`; verify via:

```bash
grep -n "platforms" Package.swift
```

Expected: `.macOS(.v14)` or higher.

- [ ] **Step 4: Run tests**

```bash
just test 2>&1 | tee /tmp/mistty-test.log
grep -E "Executed|FAIL" /tmp/mistty-test.log | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Manual verification of auto-resolve — the spec scenario**

```bash
just run
```

With `tab_bar_mode = "when_multiple_tabs"` in config:

1. Start with 1 tab. Bar hidden.
2. Press Cmd+Shift+B. Bar shows (override=`.visible`).
3. Open a new tab (Cmd+T). Bar shows — but now via `.auto` because
   configured=true matched override; the next step proves it.
4. Close that new tab (Cmd+Shift+W). Bar **hides**. Before this fix it
   would have stayed shown.

Repeat with `tab_bar_mode = "when_sidebar_hidden"`:

1. Sidebar visible, bar hidden.
2. Press Cmd+Shift+B. Bar shows.
3. Hide sidebar (Cmd+S). Bar stays shown (override resolved, configured
   now shows).
4. Show sidebar again (Cmd+S). Bar hides. Before the fix it would
   have stayed shown.

- [ ] **Step 6: Commit**

```bash
git add Mistty/App/ContentView.swift
git commit -m "$(cat <<'EOF'
fix(ui): auto-resolve tab-bar override when configured catches up

When the configured tab_bar_mode rule would produce the same visibility
as the current override, clear the override to .auto. Fires off
.onChange for sidebarVisible and activeSession.tabs.count. Restores
config-driven behavior after a temporary toggle without the user
having to press Cmd+Shift+B again.

Closes the "tab_bar_mode = when_sidebar_hidden_and_multiple_tabs seems
broken" item from PLAN.md Misc & Bugs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Tidy PLAN.md

**Files:**
- Modify: `PLAN.md` — move the tab_bar_mode bullet out of "Misc & Bugs" into "Bug fixes"

- [ ] **Step 1: Update PLAN.md**

In `PLAN.md`, remove this line from `### Misc & Bugs` (line 50):

```
- tab_bar_mode = "when_sidebar_hidden_and_multiple_tabs" seems to be broken after we added the override shortcut
```

Add a new entry at the bottom of `### Bug fixes`:

```
- Tab-bar override: the Cmd+Shift+B shortcut's override is now ephemeral per-window `@State` (was `@AppStorage`, which pinned it forever). Two presses cycles back to `.auto`, and the override auto-resolves whenever the configured `tab_bar_mode` rule would produce the same visibility (driven by `.onChange` on sidebar visibility and active tab count). See `docs/superpowers/specs/2026-04-19-tab-bar-override-design.md`
```

- [ ] **Step 2: Commit**

```bash
git add PLAN.md
git commit -m "$(cat <<'EOF'
docs(plan): record tab-bar override fix

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Design rule (override absorbs back to `.auto` when configured matches): Task 3.
- Toggle behavior (non-auto → auto): Task 1.
- Per-window `@State`: Task 2.
- Notification plumbing: Task 2.
- Test updates: Task 1.
- Migration note (orphaned UserDefaults key): no code needed; spec acknowledges and the grep in Task 2 step 7 ensures we don't leave dangling references.

All spec sections covered. No gaps.

**Placeholder scan:** No TBDs, TODOs, or "similar to" references. Every code step includes the full code block.

**Type consistency:** `tabBarOverride` (State), `TabBarVisibilityOverride` (enum), `toggled(configuredShow:)`, `effectiveShow(configuredShow:)`, `resolveOverrideIfMatched()`, `.misttyToggleTabBar` — consistent across all tasks.

**Scope check:** Four short tasks, all in two source files plus one test file plus PLAN.md. Appropriate for a single plan.
