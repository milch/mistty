import AppKit
import Foundation
import MisttyShared
import SwiftUI
import TOMLKit

struct SSHHostOverride: Sendable, Equatable {
  var hostname: String?
  var regex: String?
  var command: String

  func matches(_ host: String) -> Bool {
    if let hostname { return hostname == host }
    if let regex, let re = try? Regex(regex) {
      return host.wholeMatch(of: re) != nil
    }
    return false
  }
}

struct SSHConfig: Sendable, Equatable {
  var defaultCommand: String = "ssh"
  var hosts: [SSHHostOverride] = []

  func resolveCommand(for host: String) -> String {
    for override in hosts {
      if override.matches(host) { return override.command }
    }
    return defaultCommand
  }
}

struct CopyModeHintsConfig: Sendable, Equatable {
  var alphabet: String = "asdfghjkl"
  /// Which action uppercase letters trigger. Lowercase default is the other.
  var uppercaseAction: HintAction = .open
}

enum TabBarMode: String, Sendable, Equatable, CaseIterable {
  case always = "always"
  case never = "never"
  case whenSidebarHidden = "when_sidebar_hidden"
  case whenSidebarHiddenAndMultipleTabs = "when_sidebar_hidden_and_multiple_tabs"
  case whenMultipleTabs = "when_multiple_tabs"

  func shouldShow(sidebarVisible: Bool, tabCount: Int) -> Bool {
    switch self {
    case .always: return true
    case .never: return false
    case .whenSidebarHidden: return !sidebarVisible
    case .whenSidebarHiddenAndMultipleTabs: return !sidebarVisible && tabCount > 1
    case .whenMultipleTabs: return tabCount > 1
    }
  }
}

/// Per-window user override for tab-bar visibility, independent of `TabBarMode`.
/// Toggled via the "Toggle Tab Bar" menu command.
enum TabBarVisibilityOverride: String, Sendable, Equatable, CaseIterable {
  case auto = "auto"
  case hidden = "hidden"
  case visible = "visible"

  /// Whether the tab bar should render, given what the user's config mode would show.
  func effectiveShow(configuredShow: Bool) -> Bool {
    switch self {
    case .auto: return configuredShow
    case .hidden: return false
    case .visible: return true
    }
  }

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
}

enum TitleBarStyle: String, Sendable, Equatable, CaseIterable {
  case always = "always"
  case hiddenWithLights = "hidden_with_lights"
  case hiddenNoLights = "hidden_no_lights"

  var hasTrafficLights: Bool {
    switch self {
    case .always: return false  // lights are inside the title bar, not over content
    case .hiddenWithLights: return true
    case .hiddenNoLights: return false
    }
  }

  var contentExtendsUnderTitleBar: Bool {
    self != .always
  }

  var shouldHideWindowButtons: Bool {
    self == .hiddenNoLights
  }
}

struct UIConfig: Sendable, Equatable {
  var tabBarMode: TabBarMode = .whenMultipleTabs
  var titleBarStyle: TitleBarStyle = .hiddenWithLights
  /// Horizontal padding inside the ghostty terminal surface. `[left]` applies
  /// symmetrically; `[left, right]` splits. Maps to ghostty `window-padding-x`.
  var contentPaddingX: [Int]? = nil
  /// Vertical padding inside the ghostty terminal surface. `[top]` applies
  /// symmetrically; `[top, bottom]` splits. Maps to ghostty `window-padding-y`.
  var contentPaddingY: [Int]? = nil
  /// Whether ghostty distributes unused pixels as padding. Maps to
  /// ghostty `window-padding-balance`.
  var contentPaddingBalance: Bool? = nil

  /// Hex string (`#rrggbb` or `#rrggbbaa`) for the border between split panes.
  /// When nil, the system `NSColor.separatorColor` is used.
  var paneBorderColorHex: String? = nil
  /// Width of the border between split panes, in points.
  var paneBorderWidth: Int = 1

  /// Resolved border color between panes, with system-default fallback.
  var paneBorderColor: Color {
    if let hex = paneBorderColorHex, let color = HexColor.parse(hex) {
      return color
    }
    return Color(NSColor.separatorColor)
  }

  /// Ghostty-format config lines for the padding keys that the user has set.
  /// Suitable for writing to a temp file that `ghostty_config_load_file` reads.
  var ghosttyPaddingConfigLines: [String] {
    var lines: [String] = []
    if let xs = contentPaddingX {
      lines.append("window-padding-x = \(xs.map(String.init).joined(separator: ","))")
    }
    if let ys = contentPaddingY {
      lines.append("window-padding-y = \(ys.map(String.init).joined(separator: ","))")
    }
    if let balance = contentPaddingBalance {
      lines.append("window-padding-balance = \(balance)")
    }
    return lines
  }
}

struct MisttyConfig: Sendable, Equatable {
  /// UI-visible fallback values for the top-level ghostty passthrough keys
  /// when the user hasn't set them. Used by `SettingsView` to populate
  /// steppers / pickers; NOT emitted to ghostty on their own.
  static let defaultFontSize: Int = 13
  static let defaultFontFamily: String = ""
  static let defaultCursorStyle: String = "block"
  static let defaultScrollbackLines: Int = 10_000

  /// When non-nil these are forwarded to ghostty. A nil value means "use
  /// whatever ghostty's own default is" — which is crucially different from
  /// "equal to Mistty's display default", so that a user who explicitly
  /// writes `font_family = "monospace"` in `config.toml` still gets that
  /// exact value passed through instead of being silently swallowed.
  var fontSize: Int? = nil
  var fontFamily: String? = nil
  var cursorStyle: String? = nil
  var scrollbackLines: Int? = nil

  var sidebarVisible: Bool = true
  var popups: [PopupDefinition] = []
  var ssh: SSHConfig = SSHConfig()
  var copyModeHints: CopyModeHintsConfig = CopyModeHintsConfig()
  var ui: UIConfig = UIConfig()
  var ghostty: GhosttyPassthroughConfig = GhosttyPassthroughConfig()
  var restore: RestoreConfig = RestoreConfig()

  /// Absolute path to the `zoxide` binary. When set, `ZoxideService` uses
  /// this directly instead of probing common install locations or spawning
  /// a login shell to resolve the path. Leading `~` is expanded.
  var zoxidePath: String? = nil

  /// Writes diagnostic logs to `~/Library/Logs/Mistty/mistty-debug.log` when
  /// on. Intended for debugging intermittent bugs (tracked-window drift,
  /// focus loss, etc.). Off by default; has measurable-but-small overhead
  /// because logs go through a file handle per write.
  var debugLogging: Bool = false

  /// Multiplier applied to precision (trackpad / Magic Mouse) scroll deltas
  /// before they reach libghostty. 1.0 = raw macOS deltas (too fast in
  /// practice); 2.0 matches ghostty's own AppKit default feel. Mouse-wheel
  /// (non-precision) speed is unaffected — tune via
  /// `[ghostty] mouse-scroll-multiplier` if needed.
  var scrollMultiplier: Double = 2.0

  /// Values to show in Settings UI / Stepper bindings. Read-only surface over
  /// the optional storage.
  var resolvedFontSize: Int { fontSize ?? Self.defaultFontSize }
  var resolvedFontFamily: String { fontFamily ?? Self.defaultFontFamily }
  var resolvedCursorStyle: String { cursorStyle ?? Self.defaultCursorStyle }
  var resolvedScrollbackLines: Int { scrollbackLines ?? Self.defaultScrollbackLines }

  /// Rendered ghostty config lines assembled via the shared resolver.
  /// Top-level font/cursor first, then `[ghostty]` passthrough, then
  /// `[ui].content_padding_*` — later lines override earlier ones.
  var ghosttyConfigLines: [String] {
    var resolved = GhosttyResolvedConfig()
    resolved.fontSize = fontSize
    resolved.fontFamily = fontFamily
    resolved.cursorStyle = cursorStyle
    resolved.scrollbackLines = scrollbackLines
    resolved.passthrough = ghostty
    resolved.contentPaddingX = ui.contentPaddingX
    resolved.contentPaddingY = ui.contentPaddingY
    resolved.contentPaddingBalance = ui.contentPaddingBalance
    return resolved.configLines
  }

  static let `default` = MisttyConfig()

  static func parse(_ toml: String) throws -> MisttyConfig {
    let table = try TOMLTable(string: toml)
    var config = MisttyConfig()
    if let size = table["font_size"]?.int { config.fontSize = size }
    if let family = table["font_family"]?.string { config.fontFamily = family }
    if let cursor = table["cursor_style"]?.string { config.cursorStyle = cursor }
    if let scrollback = table["scrollback_lines"]?.int { config.scrollbackLines = scrollback }
    if let sidebar = table["sidebar_visible"]?.bool { config.sidebarVisible = sidebar }
    if let path = table["zoxide_path"]?.string {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      config.zoxidePath = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }
    if let debug = table["debug_logging"]?.bool { config.debugLogging = debug }
    if let mult = table["scroll_multiplier"]?.double, mult > 0 {
      config.scrollMultiplier = mult
    } else if let mult = table["scroll_multiplier"]?.int, mult > 0 {
      config.scrollMultiplier = Double(mult)
    }
    if let popupArray = table["popup"]?.array {
      config.popups = popupArray.compactMap { entry -> PopupDefinition? in
        guard let t = entry.table else { return nil }
        let cwdSource = (t["cwd"]?.string).flatMap(PopupCwdSource.init(rawValue:))
          ?? .activePane
        return PopupDefinition(
          name: t["name"]?.string ?? "",
          command: t["command"]?.string ?? "",
          shortcut: t["shortcut"]?.string,
          width: max(0.1, min(1.0, t["width"]?.double ?? 0.8)),
          height: max(0.1, min(1.0, t["height"]?.double ?? 0.8)),
          closeOnExit: t["close_on_exit"]?.bool ?? true,
          cwdSource: cwdSource,
          shellWrap: t["shell_wrap"]?.bool ?? true
        )
      }
    }
    if let sshTable = table["ssh"]?.table {
      if let defaultCmd = sshTable["default_command"]?.string {
        config.ssh.defaultCommand = defaultCmd
      }
      if let hostArray = sshTable["host"]?.array {
        config.ssh.hosts = hostArray.compactMap { entry -> SSHHostOverride? in
          guard let t = entry.table else { return nil }
          return SSHHostOverride(
            hostname: t["hostname"]?.string,
            regex: t["regex"]?.string,
            command: t["command"]?.string ?? config.ssh.defaultCommand
          )
        }
      }
    }
    if let copyMode = table["copy_mode"]?.table,
       let hints = copyMode["hints"]?.table {
      if let alpha = hints["alphabet"]?.string, !alpha.isEmpty {
        config.copyModeHints.alphabet = alpha
      }
      if let ua = hints["uppercase_action"]?.string {
        switch ua {
        case "open": config.copyModeHints.uppercaseAction = .open
        case "copy": config.copyModeHints.uppercaseAction = .copy
        default: break
        }
      }
    }
    if let uiTable = table["ui"]?.table {
      if let mode = uiTable["tab_bar_mode"]?.string,
         let parsed = TabBarMode(rawValue: mode) {
        config.ui.tabBarMode = parsed
      }
      if let style = uiTable["title_bar_style"]?.string,
         let parsed = TitleBarStyle(rawValue: style) {
        config.ui.titleBarStyle = parsed
      }
      config.ui.contentPaddingX = parsePadding(uiTable["content_padding_x"])
      config.ui.contentPaddingY = parsePadding(uiTable["content_padding_y"])
      if let balance = uiTable["content_padding_balance"]?.bool {
        config.ui.contentPaddingBalance = balance
      }
      if let hex = uiTable["pane_border_color"]?.string,
         HexColor.isValid(hex) {
        config.ui.paneBorderColorHex = hex
      }
      if let w = uiTable["pane_border_width"]?.int, w >= 0 {
        config.ui.paneBorderWidth = w
      }
    }
    if let ghosttyTable = table["ghostty"]?.table {
      config.ghostty = GhosttyPassthroughConfig.parse(ghosttyTable)
    }
    if let restoreTable = table["restore"]?.table,
       let commandArray = restoreTable["command"]?.array {
      config.restore.commands = commandArray.compactMap { entry -> RestoreCommandRule? in
        guard let t = entry.table,
              let match = t["match"]?.string, !match.isEmpty
        else { return nil }
        let strategy = t["strategy"]?.string
        return RestoreCommandRule(
          match: match,
          strategy: (strategy?.isEmpty == true) ? nil : strategy
        )
      }
    }
    return config
  }

  /// Serialize `[4]` as `4` and `[4, 2]` as `[4, 2]` for round-trip symmetry.
  private func formatPadding(_ values: [Int]) -> String {
    if values.count == 1 { return "\(values[0])" }
    return "[" + values.map(String.init).joined(separator: ", ") + "]"
  }

  /// Accepts `4` (int) or `[4, 2]` (array) and returns a non-empty `[Int]`.
  private static func parsePadding(_ value: TOMLValueConvertible?) -> [Int]? {
    if let single = value?.int { return [single] }
    if let arr = value?.array {
      let ints = arr.compactMap { $0.int }
      return ints.isEmpty ? nil : ints
    }
    return nil
  }

  static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")
  }

  /// Load and parse `config.toml`. Returns Mistty defaults when the file is
  /// missing or empty; throws when the file exists but is malformed so that
  /// the caller can surface the error to the user instead of silently
  /// swallowing it.
  static func loadThrowing(from url: URL = configURL) throws -> MisttyConfig {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return .default
    }
    return try parse(contents)
  }

  /// Convenience for callers that don't care about the parse error. Falls
  /// back to defaults; prefer `loadThrowing` when you want to show the user
  /// what went wrong.
  static func load() -> MisttyConfig {
    loadedAtLaunch.config
  }

  /// Single source of truth for the parse of `config.toml` at app launch.
  /// Static `let` runs exactly once, so we avoid multiple disk reads and
  /// multiple swallows of the same parse error. Consumers that need a fresh
  /// read after the user edits the file on disk — currently only
  /// `SettingsView` — should call `loadThrowing(from:)` directly.
  static let loadedAtLaunch: (config: MisttyConfig, parseError: Error?) = {
    do { return (try loadThrowing(), nil) }
    catch { return (.default, error) }
  }()

  /// Escape a string for safe TOML serialization.
  private func tomlEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  /// Emit a passthrough value using its recorded TOML kind so the file
  /// round-trips without coercion: `term = "true"` stays a string,
  /// `background-opacity = 0.95` stays a float, etc.
  private func formatPassthroughValue(_ entry: GhosttyPassthroughEntry) -> String {
    switch entry.kind {
    case .bool, .int, .double: return entry.value
    case .string: return "\"\(tomlEscape(entry.value))\""
    }
  }

  // TODO: `save()` serializes known fields but drops comments and any keys
  // Mistty hasn't modelled (unknown top-level entries, custom sections).
  // Fine today because only `SettingsView` calls this, but worth replacing
  // with a CST-preserving TOML edit (or scoping the writes to only the keys
  // that changed) before we ship more config surface.
  func save(to url: URL = configURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var lines: [String] = []
    if let size = fontSize { lines.append("font_size = \(size)") }
    if let family = fontFamily {
      lines.append("font_family = \"\(tomlEscape(family))\"")
    }
    if let cursor = cursorStyle {
      lines.append("cursor_style = \"\(tomlEscape(cursor))\"")
    }
    if let scrollback = scrollbackLines {
      lines.append("scrollback_lines = \(scrollback)")
    }
    lines.append("sidebar_visible = \(sidebarVisible)")
    if debugLogging {
      lines.append("debug_logging = true")
    }
    if scrollMultiplier != MisttyConfig().scrollMultiplier {
      lines.append("scroll_multiplier = \(scrollMultiplier)")
    }
    for popup in popups {
      lines.append("")
      lines.append("[[popup]]")
      lines.append("name = \"\(popup.name)\"")
      lines.append("command = \"\(popup.command)\"")
      if let shortcut = popup.shortcut {
        lines.append("shortcut = \"\(shortcut)\"")
      }
      lines.append("width = \(popup.width)")
      lines.append("height = \(popup.height)")
      lines.append("close_on_exit = \(popup.closeOnExit)")
      if popup.cwdSource != .activePane {
        lines.append("cwd = \"\(popup.cwdSource.rawValue)\"")
      }
      if !popup.shellWrap {
        lines.append("shell_wrap = false")
      }
    }
    if ssh.defaultCommand != "ssh" || !ssh.hosts.isEmpty {
      lines.append("")
      lines.append("[ssh]")
      lines.append("default_command = \"\(tomlEscape(ssh.defaultCommand))\"")
      for host in ssh.hosts {
        lines.append("")
        lines.append("[[ssh.host]]")
        if let hostname = host.hostname {
          lines.append("hostname = \"\(tomlEscape(hostname))\"")
        }
        if let regex = host.regex {
          lines.append("regex = \"\(tomlEscape(regex))\"")
        }
        lines.append("command = \"\(tomlEscape(host.command))\"")
      }
    }
    if copyModeHints != CopyModeHintsConfig() {
      lines.append("")
      lines.append("[copy_mode.hints]")
      lines.append("alphabet = \"\(tomlEscape(copyModeHints.alphabet))\"")
      let ua = copyModeHints.uppercaseAction == .open ? "open" : "copy"
      lines.append("uppercase_action = \"\(ua)\"")
    }
    if ui != UIConfig() {
      lines.append("")
      lines.append("[ui]")
      if ui.tabBarMode != UIConfig().tabBarMode {
        lines.append("tab_bar_mode = \"\(ui.tabBarMode.rawValue)\"")
      }
      if ui.titleBarStyle != UIConfig().titleBarStyle {
        lines.append("title_bar_style = \"\(ui.titleBarStyle.rawValue)\"")
      }
      if let xs = ui.contentPaddingX {
        lines.append("content_padding_x = \(formatPadding(xs))")
      }
      if let ys = ui.contentPaddingY {
        lines.append("content_padding_y = \(formatPadding(ys))")
      }
      if let balance = ui.contentPaddingBalance {
        lines.append("content_padding_balance = \(balance)")
      }
      if let hex = ui.paneBorderColorHex {
        lines.append("pane_border_color = \"\(hex)\"")
      }
      if ui.paneBorderWidth != UIConfig().paneBorderWidth {
        lines.append("pane_border_width = \(ui.paneBorderWidth)")
      }
    }
    if !ghostty.entries.isEmpty {
      lines.append("")
      lines.append("[ghostty]")
      // Group entries by key in first-seen order so round-tripped arrays
      // collapse back into a single TOML list assignment.
      var order: [String] = []
      var grouped: [String: [GhosttyPassthroughEntry]] = [:]
      for e in ghostty.entries {
        if grouped[e.key] == nil { order.append(e.key) }
        grouped[e.key, default: []].append(e)
      }
      for key in order {
        let values = grouped[key] ?? []
        if values.count == 1 {
          lines.append("\(key) = \(formatPassthroughValue(values[0]))")
        } else {
          let joined = values.map(formatPassthroughValue).joined(separator: ", ")
          lines.append("\(key) = [\(joined)]")
        }
      }
    }
    if !restore.commands.isEmpty {
      for rule in restore.commands {
        lines.append("")
        lines.append("[[restore.command]]")
        lines.append("match = \"\(tomlEscape(rule.match))\"")
        if let strategy = rule.strategy, !strategy.isEmpty {
          lines.append("strategy = \"\(tomlEscape(strategy))\"")
        }
      }
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }
}
