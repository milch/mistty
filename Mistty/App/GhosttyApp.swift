import AppKit
import GhosttyKit

// MARK: - C Callbacks (top-level, no captures)

/// Called from a background thread when ghostty needs attention.
/// Must dispatch to main thread.
private let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
    guard let userdata else { return }
    let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.tick()
    }
}

/// Called when ghostty wants the apprt to perform an action.
private let actionCallback: ghostty_runtime_action_cb = { app, target, action in
    switch action.tag {
    case GHOSTTY_ACTION_RENDER:
        // Render is handled by ghostty's own Metal layer
        return true
    case GHOSTTY_ACTION_SET_TITLE:
        // Could update window title here
        return true
    case GHOSTTY_ACTION_CLOSE_WINDOW:
        return true
    case GHOSTTY_ACTION_CELL_SIZE:
        return true
    case GHOSTTY_ACTION_SIZE_LIMIT:
        return true
    case GHOSTTY_ACTION_INITIAL_SIZE:
        return true
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        return true
    default:
        return false
    }
}

/// Clipboard read callback (stub).
private let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { userdata, clipboard, state in
    guard let state else { return }
    // Provide clipboard content
    let pasteboard = NSPasteboard.general
    if let str = pasteboard.string(forType: .string) {
        str.withCString { ptr in
            // We need the surface from userdata to complete the request
            // For now this is a minimal stub
        }
    }
}

/// Clipboard confirm read callback (stub).
private let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { userdata, str, state, request in
    // Auto-confirm for spike
    guard let state else { return }
}

/// Clipboard write callback.
private let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { userdata, clipboard, content, count, confirm in
    guard let content, count > 0 else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let data = content.pointee.data {
        pasteboard.setString(String(cString: data), forType: .string)
    }
}

/// Close surface callback (stub).
private let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { userdata, processAlive in
    // Minimal stub - in a real app we'd close the tab/window
}

// MARK: - GhosttyAppManager

@MainActor
final class GhosttyAppManager {
    static let shared = GhosttyAppManager()

    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private var config: ghostty_config_t?

    private init() {
        // 1. Initialize ghostty
        let initResult = ghostty_init(0, nil)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[GhosttyAppManager] ghostty_init failed: \(initResult)")
            return
        }

        // 2. Create and load config
        guard let cfg = ghostty_config_new() else {
            print("[GhosttyAppManager] ghostty_config_new failed")
            return
        }

        // Load Mistty's own ghostty config (always separate from Ghostty.app config)
        let misttyConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mistty/ghostty.conf").path
        if FileManager.default.fileExists(atPath: misttyConfigPath) {
            misttyConfigPath.withCString { path in
                ghostty_config_load_file(cfg, path)
            }
        }
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Log any config diagnostics
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                print("[GhosttyAppManager] config diagnostic: \(String(cString: msg))")
            }
        }

        // 3. Build runtime config with C callbacks
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var runtimeCfg = ghostty_runtime_config_s(
            userdata: selfPtr,
            supports_selection_clipboard: false,
            wakeup_cb: wakeupCallback,
            action_cb: actionCallback,
            read_clipboard_cb: readClipboardCallback,
            confirm_read_clipboard_cb: confirmReadClipboardCallback,
            write_clipboard_cb: writeClipboardCallback,
            close_surface_cb: closeSurfaceCallback
        )

        // 4. Create the app
        self.app = ghostty_app_new(&runtimeCfg, cfg)
        if self.app == nil {
            print("[GhosttyAppManager] ghostty_app_new failed")
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}
