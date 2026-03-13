# Popup Windows Design

## Overview

Session-scoped popup terminal overlays, configurable via config file, CLI, and preferences pane. Popups are pane overlays rendered in a ZStack above the current tab content, reusing existing pane/surface infrastructure.

## Data Model

### PopupDefinition (config)

```swift
struct PopupDefinition: Codable, Sendable, Equatable {
    let name: String           // e.g. "lazygit", "btop"
    let command: String        // e.g. "lazygit", "btop"
    let shortcut: String?      // e.g. "cmd+shift+g"
    let width: Double          // 0.0-1.0 percentage of window
    let height: Double         // 0.0-1.0 percentage of window
    let closeOnExit: Bool      // auto-close when process exits
}
```

### PopupState (live instance)

```swift
@Observable
@MainActor
final class PopupState: Identifiable {
    let id: Int               // from SessionStore ID counter
    let definition: PopupDefinition
    let pane: MisttyPane      // the actual terminal surface
    var isVisible: Bool       // toggled on/off
}
```

### Session integration

On MisttySession:
- `var popups: [PopupState] = []`
- `var activePopup: PopupState?` (at most one visible at a time)

On SessionStore: `nextPopupId` counter.

### Config file format

```toml
[[popup]]
name = "lazygit"
command = "lazygit"
shortcut = "cmd+shift+g"
width = 0.8
height = 0.8
close_on_exit = true

[[popup]]
name = "btop"
command = "btop"
shortcut = "cmd+shift+b"
width = 0.9
height = 0.9
close_on_exit = false
```

## UI Rendering

The popup renders as a centered overlay in a ZStack on top of the existing pane layout:

```
┌─────────────────────────────────────┐
│ Tab Bar                             │
├─────────────────────────────────────┤
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
│░░░┌─── lazygit ──────────────┐░░░░░│
│░░░│                          │░░░░░│
│░░░│   (ghostty surface)     │░░░░░│
│░░░│                          │░░░░░│
│░░░│                          │░░░░░│
│░░░└──────────────────────────┘░░░░░│
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
└─────────────────────────────────────┘
```

Components:
1. Semi-transparent dark backdrop (click-to-dismiss)
2. Centered popup pane sized as percentage of window
3. Subtle border/shadow
4. Popup name in small header bar

### Keyboard handling

When popup is visible, all keyboard input goes to the popup's ghostty surface. Exceptions:
- The popup's toggle shortcut (hides it)
- Cmd+W (closes popup entirely, kills process)

Opening a popup makes its surface first responder. Closing returns focus to the previously active pane.

## Popup Lifecycle

### First open

1. User presses configured shortcut
2. Look up PopupDefinition by shortcut
3. Create PopupState with new MisttyPane (exec = command, directory = session.directory)
4. Set isVisible = true, session.activePopup = popupState
5. Lazy surfaceView initializes, launching the command

### Toggle (subsequent presses)

- Visible → hide (isVisible = false, activePopup = nil, return focus)
- Hidden → show (isVisible = true, activePopup = popupState, focus surface)
- Process keeps running when hidden

### Close on exit

- Listen for ghosttyCloseSurface notification on popup's pane
- closeOnExit == true → remove PopupState from session
- closeOnExit == false → hide popup, keep state

### Cmd+W on popup

Closes entirely — removes PopupState, releases pane/surface.

## CLI Integration

New XPC protocol methods:
```swift
func openPopup(sessionId: Int, name: String?, exec: String?, width: Double, height: Double, closeOnExit: Bool, reply: ...)
func closePopup(sessionId: Int, popupId: Int, reply: ...)
func listPopups(sessionId: Int, reply: ...)
```

CLI commands:
```
mistty-cli popup open --name "lazygit"
mistty-cli popup open --exec "fzf" --width 0.8 --height 0.5
mistty-cli popup close
mistty-cli popup list --session 1
```

## Shortcut Registration

Popup shortcuts registered as SwiftUI .commands in MisttyApp.swift. Read from MisttyConfig.popups at app launch. Post .misttyPopupToggle notifications with popup name. ContentView handles toggle.

Shortcuts are dynamic from config. Update on app restart (no live-reloading).

## Preferences Pane

Add "Popups" section to SettingsView:
- List configured popups (name, command, shortcut, size, close behavior)
- Add/edit/remove popup definitions
- Changes write to config.toml

Extend MisttyConfig to parse/serialize `[[popup]]` entries.

## Out of Scope

- Multiple simultaneous visible popups
- Positioning options beyond centered
- Live config reloading
- Popup restart on exit
