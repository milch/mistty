# Spike Conclusions

## What worked

The spike successfully renders a fully functional terminal in a SwiftUI window using libghostty. Text input, output, scrolling, and resize all work correctly.

## libghostty integration patterns

### Lifecycle

1. `ghostty_init(0, nil)` — once at process start
2. `ghostty_config_new()` → `ghostty_config_load_default_files()` → `ghostty_config_finalize()` — creates config from `~/.config/ghostty/config`
3. `ghostty_app_new(&runtime_cfg, config)` — creates the app with 6 callbacks
4. Per-pane: `ghostty_surface_new(app, &surface_cfg)` — creates a surface bound to an NSView
5. Cleanup: `ghostty_surface_free()`, `ghostty_app_free()`, `ghostty_config_free()`

### Key architectural constraints

- **One `ghostty_app_t` per process.** The app is a singleton. All surfaces share it.
- **NSView pointer passed at surface creation.** The surface config takes `Unmanaged.passUnretained(view).toOpaque()` as `platform.macos.nsview`. libghostty installs its own `CALayer` on this view — no Metal setup from our side.
- **Surface size in pixels, not points.** Must multiply by `backingScaleFactor`.
- **`wakeup_cb` fires from background threads.** Must `DispatchQueue.main.async` to call `ghostty_app_tick()`.
- **`userdata` pattern for callbacks.** C function pointers can't capture Swift context — use `Unmanaged.passUnretained(self).toOpaque()` and recover with `Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()`.

### Swift 6 concurrency

- `nonisolated(unsafe)` needed for stored C pointers (`ghostty_app_t?`, `ghostty_surface_t?`) accessed from `deinit`
- `@preconcurrency NSTextInputClient` conformance for `@MainActor` views
- C callbacks must be top-level closures or functions (no captures)

### What the NSViewRepresentable wrapper needs

Minimal requirements for a working surface:
1. `NSView` subclass with `wantsLayer = true`
2. Create surface in `init(frame:)` with the NSView pointer
3. Override `setFrameSize` to call `ghostty_surface_set_size` with pixel dimensions
4. Override `viewDidMoveToWindow` to set initial size and become first responder
5. Forward keyboard via `interpretKeyEvents` + `NSTextInputClient.insertText`
6. Forward mouse via `ghostty_surface_mouse_button`, `ghostty_surface_mouse_pos`, `ghostty_surface_mouse_scroll`

### Multiple surfaces (one per pane)

Each pane gets its own `ghostty_surface_t` bound to its own `NSView`. All surfaces share the single `ghostty_app_t`. This means:
- **App-managed layout** — libghostty does not manage splits or tabs. Our SwiftUI layout (HSplitView/VSplitView wrapping PaneLayoutView) is the right approach.
- **Independent surfaces** — each pane's surface is fully independent. No coordination needed between surfaces at the libghostty level.

### Action callback

The `action_cb` is where libghostty communicates events back to the host app. Key actions for MVP:
- `GHOSTTY_ACTION_SET_TITLE` — update tab title from terminal
- `GHOSTTY_ACTION_RING_BELL` — bell indicator in sidebar
- `GHOSTTY_ACTION_CLOSE_WINDOW` — process exited, close pane
- `GHOSTTY_ACTION_CELL_SIZE` / `GHOSTTY_ACTION_INITIAL_SIZE` — sizing hints

### Linker requirements

Package.swift needs:
- `.linkedLibrary("c++")` — for SPIRV-Cross/glslang C++ code in libghostty
- `.linkedFramework("Carbon")` — for `TISCopyCurrentKeyboardLayoutInputSource`

### Build requirements

- Zig 0.15.2 via Nix flake
- Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- System Xcode SDK (Nix shell must `unset SDKROOT` and `unset DEVELOPER_DIR`)
- Build command: `zig build -Dapp-runtime=none -Doptimize=ReleaseFast` in `vendor/ghostty/`
- Output: `vendor/ghostty/macos/GhosttyKit.xcframework`

## Phase 1 adjustments

The original design holds up well. Only minor adjustments needed:

1. **`GhosttyAppManager` singleton** — add to Phase 1 as a proper class (not in Spike/). It manages the `ghostty_app_t` lifecycle and the runtime callbacks.

2. **`MisttyPane` needs to own a `TerminalSurfaceView`** — the pane model class should create/destroy the ghostty surface. The `TerminalSurfaceView` from the spike can be promoted to production code with cleanup.

3. **Action callback routing** — the `action_cb` needs to look up the `MisttyPane` via `ghostty_surface_userdata()` and route events (title changes, bell, close) up through the session model. This replaces the stub implementation from the spike.

4. **Config integration** — Mistty's own `~/.config/mistty/config.toml` is separate from Ghostty's config. But libghostty loads `~/.config/ghostty/config` for terminal-level settings (font, colors, etc.). For MVP, this is fine — users configure terminal appearance via Ghostty config. Mistty config handles app-level settings (sidebar, keybindings).

5. **No changes needed to**: the session/tab/pane protocol design, the recursive PaneLayout tree, the sidebar/tab bar views, or the session manager overlay.
