import Foundation
import TOMLKit

/// Types we allow a passthrough value to have. Tracking the type alongside the
/// rendered string lets `save()` round-trip the user's `config.toml` without
/// type coercion bugs — e.g. `enquiry-response = "123"` stays a string instead
/// of being re-emitted as an unquoted integer.
public enum GhosttyPassthroughValueKind: Sendable, Equatable {
  case bool
  case int
  case double
  case string
}

/// One rendered ghostty config line, e.g. (`font-family`, `JetBrainsMono Nerd Font`).
/// Repeatable ghostty keys (font-family, palette, keybind, etc.) appear as
/// multiple entries with the same `key`.
public struct GhosttyPassthroughEntry: Sendable, Equatable {
  public var key: String
  public var value: String
  public var kind: GhosttyPassthroughValueKind

  public init(key: String, value: String, kind: GhosttyPassthroughValueKind) {
    self.key = key
    self.value = value
    self.kind = kind
  }
}

/// Passthrough for arbitrary ghostty config keys placed under `[ghostty]` in
/// Mistty's `config.toml`. Denied keys (listed below) are dropped because they
/// would conflict with Mistty's own chrome, window, tab, split, keybind or
/// lifecycle management. Users can still override those directly in
/// `~/.config/mistty/ghostty.conf` if they know what they're doing.
public struct GhosttyPassthroughConfig: Sendable, Equatable {
  public var entries: [GhosttyPassthroughEntry] = []

  public init(entries: [GhosttyPassthroughEntry] = []) {
    self.entries = entries
  }

  /// Ghostty keys that Mistty itself manages. Dropped when present under
  /// `[ghostty]` — with a diagnostic so the user knows why.
  public static let deniedKeys: Set<String> = [
    // Window geometry / lifecycle / chrome — Mistty owns the window.
    "window-width", "window-height",
    "window-position-x", "window-position-y",
    "window-padding-x", "window-padding-y", "window-padding-balance",
    "window-decoration", "window-save-state", "window-step-resize",
    "window-title-font-family", "window-subtitle",
    "window-inherit-working-directory", "window-inherit-font-size",
    "window-new-tab-position", "window-show-tab-bar",
    "window-titlebar-background", "window-titlebar-foreground",
    // `window-theme` IS allowed — Mistty doesn't use ghostty's chrome but
    // ghostty uses this key to pick between `light:...` and `dark:...`
    // variants in `theme = "light:X,dark:Y"` strings. Emitted below with a
    // `system` default so ghostty follows macOS appearance automatically.
    "maximize", "fullscreen", "title", "class", "x11-instance-name",
    "focus-follows-mouse",
    // Splits — Mistty owns pane layout; see `ui.pane_border_*`.
    "split-divider-color", "split-inherit-working-directory", "split-preserve-zoom",
    // Tabs — Mistty owns the tab bar.
    "tab-inherit-working-directory",
    // Keybinds / key remap — Mistty intercepts keys before ghostty sees them,
    // so a ghostty-level remap only applies to events Mistty chooses to
    // forward, which is confusing. Configure keybinds through Mistty.
    "keybind", "key-remap",
    // Command / working directory — Mistty sets these per session.
    "command", "initial-command", "initial-window",
    "working-directory", "input",
    // Quick terminal — Mistty has its own popup system.
    "quick-terminal-position", "quick-terminal-size", "quick-terminal-screen",
    "quick-terminal-animation-duration", "quick-terminal-autohide",
    "quick-terminal-space-behavior", "quick-terminal-keyboard-interactivity",
    // macOS chrome / app-level — Mistty manages.
    "macos-window-shadow", "macos-hidden", "macos-applescript",
    "macos-icon", "macos-custom-icon", "macos-icon-frame",
    "macos-icon-ghost-color", "macos-icon-screen-color",
    "macos-shortcuts", "macos-window-buttons", "macos-titlebar-style",
    "macos-titlebar-proxy-icon", "macos-dock-drop-behavior",
    "macos-non-native-fullscreen",
    // Transparency / blur — accepted by ghostty but Mistty's NSWindow is
    // opaque (`isOpaque = true`, no vibrancy view), so these silently do
    // nothing. Deny until Mistty wires the window layer explicitly.
    "background-opacity", "background-opacity-cells", "background-blur",
    // App lifecycle / config loading — Mistty manages.
    "auto-update", "auto-update-channel",
    "config-file", "config-default-files",
    "quit-after-last-window-closed", "quit-after-last-window-closed-delay",
    "undo-timeout", "command-palette-entry",
    // Linux / GTK only — silently ignored on macOS either way, but deny so
    // users learn to put Linux-specific bits behind their own logic.
    "linux-cgroup", "linux-cgroup-memory-limit",
    "linux-cgroup-processes-limit", "linux-cgroup-hard-fail",
    "gtk-single-instance", "gtk-titlebar", "gtk-tabs-location",
    "gtk-titlebar-hide-when-maximized", "gtk-toolbar-style",
    "gtk-titlebar-style", "gtk-wide-tabs", "gtk-opengl-debug",
    "gtk-custom-css", "gtk-quick-terminal-layer",
    "gtk-quick-terminal-namespace", "language", "async-backend",
    "app-notifications", "freetype-load-flags",
  ]

  /// Emitted lines in the table's natural order (alphabetical, with `theme`
  /// lifted to the front — see `parse`). Each entry is one `key = value` line,
  /// unquoted, as ghostty's config parser expects.
  public var configLines: [String] {
    entries.map { "\($0.key) = \($0.value)" }
  }

  /// Parse a TOML `[ghostty]` table into passthrough entries. Scalars emit
  /// one entry; arrays emit one entry per element so repeatable ghostty keys
  /// like `font-family` / `palette` work. Denied keys are dropped with a
  /// diagnostic, as are nested tables and TOML date/time values (ghostty has
  /// no config for those — almost always a user mistake).
  public static func parse(_ table: TOMLTable) -> GhosttyPassthroughConfig {
    var config = GhosttyPassthroughConfig()
    // TOMLKit's `keys` is alphabetical (toml++ uses a sorted map). Ghostty's
    // `theme` key implicitly sets palette/background/foreground, so emit it
    // FIRST and let any user-provided overrides (still alphabetical) win.
    // Single-pass partition — `stablePartition` keeps the non-`theme` keys
    // in their original alphabetical order while lifting `theme` to index 0.
    var orderedKeys = table.keys
    if let themeIdx = orderedKeys.firstIndex(of: "theme"), themeIdx != orderedKeys.startIndex {
      orderedKeys.remove(at: themeIdx)
      orderedKeys.insert("theme", at: orderedKeys.startIndex)
    }
    for key in orderedKeys {
      guard let value = table[key] else { continue }
      if deniedKeys.contains(key) {
        FileHandle.standardError.write(
          Data("[mistty] [ghostty] key '\(key)' is managed by Mistty and was ignored\n".utf8))
        continue
      }
      let rendered = renderGhosttyValue(value, keyForDiagnostic: key)
      for pair in rendered {
        config.entries.append(
          GhosttyPassthroughEntry(key: key, value: pair.value, kind: pair.kind))
      }
    }
    return config
  }

  /// Renders a TOML value as one or more rendered passthrough values. Arrays
  /// are flattened so the caller emits one line per element.
  private static func renderGhosttyValue(
    _ value: TOMLValueConvertible,
    keyForDiagnostic key: String
  ) -> [(value: String, kind: GhosttyPassthroughValueKind)] {
    if let b = value.bool { return [(b ? "true" : "false", .bool)] }
    if let i = value.int { return [("\(i)", .int)] }
    if let d = value.double { return [("\(d)", .double)] }
    if let s = value.string { return [(s, .string)] }
    if let arr = value.array {
      return arr.flatMap { renderGhosttyValue($0, keyForDiagnostic: key) }
    }
    // Nested tables, TOML dates/times. Ghostty has no such config — warn so
    // the user spots a typo like `[ghostty.font]` instead of silent drop.
    FileHandle.standardError.write(
      Data("[mistty] [ghostty] key '\(key)' has an unsupported TOML value type and was ignored\n".utf8))
    return []
  }
}

/// Resolved ghostty config produced from Mistty's `config.toml`, ready to be
/// written to a temp file that `ghostty_config_load_file` consumes (or dumped
/// to stdout by `mistty-cli config show`). Intentionally decoupled from the
/// full `MisttyConfig` so that MisttyCLI and MisttyShared don't have to depend
/// on SwiftUI / AppKit.
public struct GhosttyResolvedConfig: Sendable, Equatable {
  public var fontSize: Int?
  public var fontFamily: String?
  public var cursorStyle: String?
  /// In lines. Converted to `scrollback-limit` bytes at render time using
  /// ~1 000 bytes/line — ghostty's own default is 10 000 000 bytes (decimal
  /// MB, see `vendor/ghostty/src/config/Config.zig:1385`), which lines up
  /// with the historical 10 000-line scrollback budget at 1 000 bytes/line.
  public var scrollbackLines: Int?
  public var passthrough: GhosttyPassthroughConfig = GhosttyPassthroughConfig()
  public var contentPaddingX: [Int]?
  public var contentPaddingY: [Int]?
  public var contentPaddingBalance: Bool?

  public init() {}

  /// Ghostty config file lines. Top-level font/cursor first so `[ghostty]`
  /// passthrough entries for the same key (rare but legal) override them;
  /// `[ui].content_padding_*` last so Mistty-managed padding always wins.
  ///
  /// Empty strings for `font_family` / `cursor_style` are treated as "don't
  /// forward" rather than "reset" — emitting `font-family = ` would clear
  /// ghostty's entire font-family list (and anything in the user's
  /// `ghostty.conf`), which is almost certainly not what a user editing
  /// `config.toml` intends.
  public var configLines: [String] {
    var lines: [String] = []
    if let s = fontSize { lines.append("font-size = \(s)") }
    if let f = fontFamily, !f.isEmpty { lines.append("font-family = \(f)") }
    if let c = cursorStyle, !c.isEmpty { lines.append("cursor-style = \(c)") }
    if let l = scrollbackLines { lines.append("scrollback-limit = \(l * 1000)") }
    lines.append(contentsOf: passthrough.configLines)
    if let xs = contentPaddingX {
      lines.append("window-padding-x = \(xs.map(String.init).joined(separator: ","))")
    }
    if let ys = contentPaddingY {
      lines.append("window-padding-y = \(ys.map(String.init).joined(separator: ","))")
    }
    if let b = contentPaddingBalance {
      lines.append("window-padding-balance = \(b)")
    }

    // Empty resolution = empty output. Skips writing a temp file with nothing
    // but `window-theme = system` when the user hasn't configured anything.
    if lines.isEmpty { return [] }

    // Default `window-theme = system` so ghostty picks the right variant of
    // `theme = "light:X,dark:Y"` strings based on macOS appearance. Only
    // prepend when the user hasn't set `window-theme` themselves — otherwise
    // we'd emit two lines for the same key.
    if passthrough.entries.contains(where: { $0.key == "window-theme" }) {
      return lines
    }
    return ["window-theme = system"] + lines
  }

  /// Parse the relevant subset of a Mistty `config.toml` string. Throws the
  /// same `TOMLParseError` as `TOMLTable(string:)` when the input is
  /// syntactically invalid — callers are expected to surface that to the user
  /// rather than silently swallow it.
  public static func parse(_ toml: String) throws -> GhosttyResolvedConfig {
    let table = try TOMLTable(string: toml)
    var resolved = GhosttyResolvedConfig()
    if let size = table["font_size"]?.int { resolved.fontSize = size }
    if let family = table["font_family"]?.string { resolved.fontFamily = family }
    if let cursor = table["cursor_style"]?.string { resolved.cursorStyle = cursor }
    if let scrollback = table["scrollback_lines"]?.int { resolved.scrollbackLines = scrollback }
    if let uiTable = table["ui"]?.table {
      resolved.contentPaddingX = parsePadding(uiTable["content_padding_x"])
      resolved.contentPaddingY = parsePadding(uiTable["content_padding_y"])
      if let balance = uiTable["content_padding_balance"]?.bool {
        resolved.contentPaddingBalance = balance
      }
    }
    if let ghosttyTable = table["ghostty"]?.table {
      resolved.passthrough = GhosttyPassthroughConfig.parse(ghosttyTable)
    }
    return resolved
  }

  private static func parsePadding(_ value: TOMLValueConvertible?) -> [Int]? {
    if let single = value?.int { return [single] }
    if let arr = value?.array {
      let ints = arr.compactMap { $0.int }
      return ints.isEmpty ? nil : ints
    }
    return nil
  }

  /// Default location of Mistty's `config.toml`.
  public static var defaultConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")
  }

  /// Read and parse `config.toml`. Returns `(config, parseError)`; the error
  /// is non-nil when the file exists but can't be parsed, so callers can
  /// still fall through to defaults while surfacing the failure.
  public static func load(from url: URL = defaultConfigURL) -> (GhosttyResolvedConfig, Error?) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return (GhosttyResolvedConfig(), nil)
    }
    do {
      return (try parse(contents), nil)
    } catch {
      return (GhosttyResolvedConfig(), error)
    }
  }
}

/// Produces a user-facing description of a TOML parse error, including the
/// line/column when available. Defined here so callers (CLI, app alert) don't
/// have to import TOMLKit directly.
public func describeTOMLParseError(_ error: Error) -> String {
  if let parse = error as? TOMLParseError {
    return "\(parse.description) (\(parse.source.begin.debugDescription))"
  }
  return error.localizedDescription
}

