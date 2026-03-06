# libghostty API Research Notes

Research date: 2026-03-06
Source: ghostty-org/ghostty main branch, Ghostty.app 1.x installed at /Applications/Ghostty.app

---

## 1. How to Obtain libghostty

### The short answer: build from source using Zig

The installed Ghostty.app bundle at `/Applications/Ghostty.app` contains only:
- `Contents/MacOS/ghostty` — a universal (x86_64 + arm64) Mach-O executable
- `Contents/Frameworks/Sparkle.framework` — the auto-update framework

**There is no separate `.dylib`, `.a`, or `.xcframework` shipped inside the app bundle.** The ghostty C API symbols are compiled statically into the main executable. The releases page only ships `Ghostty.dmg` (the app), not a standalone library package.

### Building from source

The Ghostty build system (Zig) can produce a library via the `app_runtime = .none` configuration:

```
# On non-Darwin (produces libghostty.so / libghostty.a)
zig build -Dapp-runtime=none

# On macOS (produces an xcframework)
zig build -Dapp-runtime=none -Demit-xcframework
```

The Ghostty developers explicitly note: *"libghostty is not stable for general purpose use. It is used heavily by Ghostty on macOS but it isn't built to be reusable yet."*

### Practical approach for Mistty (spike phase)

The simplest path for the spike:
1. Clone the Ghostty repo: `git clone https://github.com/ghostty-org/ghostty`
2. Install Zig (matching version used by Ghostty — check `build.zig.zon`)
3. Run `zig build -Dapp-runtime=none` to build the xcframework
4. Link the resulting xcframework into the Mistty Xcode project

Alternatively, since we just need symbols present for the spike, we can link directly against the installed `Ghostty` binary by treating it as a dylib (all the `ghostty_*` symbols are present in the executable). This is a hack and not suitable for distribution.

The header file is at `include/ghostty.h` in the Ghostty source tree and must be copied into the Mistty project.

---

## 2. Surface Lifecycle

```
ghostty_init()
  |
  v
ghostty_config_new() -> ghostty_config_load_default_files() -> ghostty_config_finalize()
  |
  v
ghostty_app_new(&runtime_cfg, config)        // creates the app context
  |
  v
ghostty_surface_config_new()                  // get default surface config
  | populate:
  |   .platform_tag = GHOSTTY_PLATFORM_MACOS
  |   .platform.macos.nsview = <NSView* pointer as void*>
  |   .userdata = <your context pointer>
  |   .scale_factor = window.backingScaleFactor
  v
ghostty_surface_new(app, &surface_cfg)        // creates a terminal surface
  |
  | (runtime running — events flowing)
  |
  v
ghostty_surface_set_size(surface, width_px, height_px)
ghostty_surface_set_content_scale(surface, sx, sy)
ghostty_surface_set_focus(surface, true)
ghostty_surface_set_display_id(surface, displayID)  // for vsync
  |
  v
  [render loop — see section 4]
  [input events — see section 5]
  |
  v
ghostty_surface_free(surface)
ghostty_app_free(app)
ghostty_config_free(config)
```

---

## 3. Key C API Function Signatures

All types are opaque `void*` handles.

### Initialization

```c
// Must be called once before anything else
int ghostty_init(uintptr_t argc, char** argv);

// Info about the build
ghostty_info_s ghostty_info(void);   // returns build mode, version, etc.
```

### Configuration

```c
ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
void ghostty_config_load_default_files(ghostty_config_t);   // load ~/.config/ghostty/config
void ghostty_config_finalize(ghostty_config_t);             // must call before use
bool ghostty_config_get(ghostty_config_t, void* out, const char* key, uintptr_t key_len);
```

### App Lifecycle

```c
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
void ghostty_app_tick(ghostty_app_t);           // process pending events — call from main thread
void ghostty_app_set_focus(ghostty_app_t, bool);
void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);
```

### Surface Management

```c
ghostty_surface_config_s ghostty_surface_config_new();
ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
void* ghostty_surface_userdata(ghostty_surface_t);
ghostty_app_t ghostty_surface_app(ghostty_surface_t);

// Sizing and display
void ghostty_surface_set_size(ghostty_surface_t, uint32_t width_px, uint32_t height_px);
void ghostty_surface_set_content_scale(ghostty_surface_t, double sx, double sy);
void ghostty_surface_set_focus(ghostty_surface_t, bool focused);
void ghostty_surface_set_occlusion(ghostty_surface_t, bool occluded);
void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t displayID);
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);  // cols, rows, px dimensions

// Rendering
void ghostty_surface_refresh(ghostty_surface_t);   // mark dirty, request redraw
void ghostty_surface_draw(ghostty_surface_t);       // execute one draw frame (Metal)
```

### Input

```c
// Keyboard
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
void ghostty_surface_text(ghostty_surface_t, const char* utf8, uintptr_t len);
void ghostty_surface_preedit(ghostty_surface_t, const char* utf8, uintptr_t len);  // IME

// Mouse
bool ghostty_surface_mouse_button(ghostty_surface_t,
    ghostty_input_mouse_state_e,       // PRESS or RELEASE
    ghostty_input_mouse_button_e,      // LEFT, RIGHT, MIDDLE, ...
    ghostty_input_mods_e);
void ghostty_surface_mouse_pos(ghostty_surface_t, double x, double y, ghostty_input_mods_e);
void ghostty_surface_mouse_scroll(ghostty_surface_t, double dx, double dy,
    ghostty_input_scroll_mods_t);
```

### Runtime Callbacks (registered at app creation)

```c
typedef struct {
    void* userdata;
    bool  supports_selection_clipboard;

    // Called from any thread when libghostty needs the host to call ghostty_app_tick().
    // Host should dispatch to main thread.
    void (*wakeup_cb)(void* userdata);

    // Dispatches high-level actions (new window, close, set title, render, etc.)
    bool (*action_cb)(ghostty_app_t, ghostty_target_s, ghostty_action_s);

    // Clipboard
    void (*read_clipboard_cb)(void* userdata, ghostty_clipboard_e, void* state);
    void (*confirm_read_clipboard_cb)(void* userdata, const char*, void*, ghostty_clipboard_request_e);
    void (*write_clipboard_cb)(void* userdata, ghostty_clipboard_e,
                               const ghostty_clipboard_content_s*, size_t, bool);

    // Called when the shell process exits / surface should close
    void (*close_surface_cb)(void* userdata, bool process_alive);
} ghostty_runtime_config_s;
```

### Surface Config

```c
typedef struct {
    ghostty_platform_e  platform_tag;   // GHOSTTY_PLATFORM_MACOS
    ghostty_platform_u  platform;       // platform.macos.nsview = NSView* as void*
    void*               userdata;
    double              scale_factor;
    float               font_size;
    const char*         working_directory;
    const char*         command;
    ghostty_env_var_s*  env_vars;
    size_t              env_var_count;
    const char*         initial_input;
    bool                wait_after_command;
    ghostty_surface_context_e context;
} ghostty_surface_config_s;

// Platform union — macOS only needs the NSView pointer
typedef union {
    struct { void* nsview; } macos;
    struct { void* uiview; } ios;
} ghostty_platform_u;
```

---

## 4. Threading Model

- **All ghostty_* calls must happen on the main thread** (Ghostty's Swift layer uses `@MainActor` everywhere).
- The `wakeup_cb` is the sole callback that may be called from any thread. Its job is to schedule a main-thread call to `ghostty_app_tick()`.
- The renderer runs on an internal thread managed by libghostty. The host never needs to drive the GPU directly.
- `ghostty_surface_free()` should be called asynchronously (detached task) rather than inline in a deinit path to avoid deadlocks on the main actor.

---

## 5. How Rendering Works (Metal)

This is the most important non-obvious part of the API.

### libghostty owns the Metal layer

When `ghostty_surface_new()` is called with a macOS `nsview` pointer, **libghostty's Metal renderer creates an `IOSurfaceLayer` (a `CALayer` subclass) and attaches it directly to the NSView** by:

1. Setting `view.layer = iosurface_layer` (assign before enabling wantsLayer)
2. Setting `view.wantsLayer = true`

The host NSView does **not** need to set up `wantsLayer`, `makeBackingLayer()`, `MTKView`, or any CAMetalLayer itself. libghostty takes over the view's layer entirely.

### Render loop is display-callback driven

libghostty registers a display callback on its `IOSurfaceLayer` (`CALayer.setDisplayCallback`). The system's display link (CoreVideo/CoreAnimation) invokes this callback at vsync, which calls `renderer.drawFrame()` internally.

The host calls:
- `ghostty_surface_set_display_id(surface, displayID)` — to synchronize vsync to the correct display
- `ghostty_surface_refresh(surface)` — to mark the surface dirty (request a redraw on the next vsync)
- `ghostty_surface_draw(surface)` — to force an immediate draw frame

The host does **not** need to implement its own CVDisplayLink or call Metal APIs.

### When to call ghostty_surface_draw()

`ghostty_surface_draw()` is for cases where the host needs to force a synchronous draw — e.g., after a resize. Under normal operation, the display callback drives rendering automatically. `ghostty_surface_refresh()` is the lighter signal: mark dirty, let the callback flush it at the next frame.

---

## 6. Swift Bridging Requirements

To call the C API from Swift:

1. Add `ghostty.h` to the project's bridging header (or wrap it in a Swift package with a `module.modulemap`)
2. The header uses `#include <stdbool.h>`, `<stdint.h>`, `<stddef.h>` — standard, no special dependencies
3. Opaque types (`ghostty_app_t`, `ghostty_surface_t`, etc.) are `void*` in C and arrive in Swift as `OpaquePointer` or `UnsafeMutableRawPointer`
4. Swift closures cannot be passed directly as C function pointer callbacks — use `@convention(c)` global functions or static methods

Example pattern from Ghostty's own Swift layer:

```swift
var runtime_cfg = ghostty_runtime_config_s(
    userdata: Unmanaged.passUnretained(self).toOpaque(),
    supports_selection_clipboard: true,
    wakeup_cb: { userdata in MyApp.wakeup(userdata) },
    action_cb:  { app, target, action in MyApp.action(app!, target: target, action: action) },
    read_clipboard_cb: { ... },
    confirm_read_clipboard_cb: { ... },
    write_clipboard_cb: { ... },
    close_surface_cb: { ... }
)
guard let app = ghostty_app_new(&runtime_cfg, config) else { fatalError() }
```

---

## 7. NSViewRepresentable Wrapper Design

What Mistty's `SurfaceViewRepresentable` will need:

```swift
// AppKit side: an NSView subclass that owns the ghostty surface
class SurfaceView: NSView {
    var surface: ghostty_surface_t?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Do NOT set wantsLayer here — libghostty will do it
    }

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s) {
        var cfg = config
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: .init(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = window?.backingScaleFactor ?? 2.0
        surface = ghostty_surface_new(app, &cfg)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    // Forward all mouse/key events to ghostty_surface_key/mouse_*
}

// SwiftUI side
struct SurfaceRepresentable: NSViewRepresentable {
    let surfaceView: SurfaceView
    let size: CGSize

    func makeNSView(context: Context) -> SurfaceView { surfaceView }

    func updateNSView(_ view: SurfaceView, context: Context) {
        // Use explicit size from GeometryReader — viewDidLayout is unreliable on macOS 12+
        let w = UInt32(size.width)
        let h = UInt32(size.height)
        if let surface = view.surface {
            ghostty_surface_set_size(surface, w, h)
        }
    }
}
```

Key notes:
- Wrap `SurfaceView` in a `SurfaceScrollView` (as Ghostty does) if scroll behavior is needed beyond what libghostty provides
- Use `GeometryReader` in the SwiftUI layer to pass explicit sizes rather than relying on NSView layout callbacks
- The `action_cb` from the runtime config fires `GHOSTTY_ACTION_SET_TITLE`, `GHOSTTY_ACTION_CLOSE_WINDOW`, `GHOSTTY_ACTION_NEW_WINDOW`, etc. — Mistty must handle the ones it cares about

---

## 8. Known Constraints and Surprises

1. **No pre-built library in releases.** Must build from Ghostty source or use the installed app binary (the latter is only viable for local development/spike).

2. **libghostty owns the NSView's layer.** You cannot use `MTKView` or manage your own CAMetalLayer. The view must be a plain `NSView` with no custom layer configuration.

3. **API is explicitly unstable.** The header comment says: *"The documentation for the embedding API is only within the Zig source files."* This means function semantics can change without notice across Ghostty releases.

4. **No CVDisplayLink in the host.** The render loop is driven by an internal display callback registered on the layer. The host just calls `ghostty_surface_set_display_id()` to target the right screen.

5. **`ghostty_init()` call required.** Must be called once with `argc`/`argv` before anything else. Pass the process's real `argc`/`argv` or zeroed values.

6. **Main thread only.** The `wakeup_cb` is the only callback that arrives off-thread. Everything else must be on the main thread. Use `DispatchQueue.main.async` in `wakeup_cb` to call `ghostty_app_tick()`.

7. **Zig toolchain required to build.** Ghostty uses Zig as its build system and primary language. Building libghostty requires installing Zig (specific version — see the Ghostty repo's `build.zig.zon`).

8. **Config must be finalized.** `ghostty_config_finalize()` must be called before passing the config to `ghostty_app_new()`, otherwise the app will use stale/invalid configuration.

---

## 9. Recommended Next Steps

1. Clone Ghostty repo, install correct Zig version, run `zig build -Dapp-runtime=none` to produce the xcframework
2. Copy `include/ghostty.h` into Mistty project
3. Add xcframework to Xcode (or link the built static library)
4. Write a minimal Swift bridging module that calls `ghostty_init` → `ghostty_config_*` → `ghostty_app_new` → `ghostty_surface_new` and verify a surface appears on screen (Task P0-T3 and P0-T4)
