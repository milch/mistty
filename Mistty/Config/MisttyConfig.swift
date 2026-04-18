import Foundation
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

  /// Next override after a user toggle: force the opposite of whatever is currently showing.
  func toggled(configuredShow: Bool) -> TabBarVisibilityOverride {
    effectiveShow(configuredShow: configuredShow) ? .hidden : .visible
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
  var fontSize: Int = 13
  var fontFamily: String = "monospace"
  var cursorStyle: String = "block"
  var scrollbackLines: Int = 10000
  var sidebarVisible: Bool = true
  var popups: [PopupDefinition] = []
  var ssh: SSHConfig = SSHConfig()
  var copyModeHints: CopyModeHintsConfig = CopyModeHintsConfig()
  var ui: UIConfig = UIConfig()

  static let `default` = MisttyConfig()

  static func parse(_ toml: String) throws -> MisttyConfig {
    let table = try TOMLTable(string: toml)
    var config = MisttyConfig()
    if let size = table["font_size"]?.int { config.fontSize = size }
    if let family = table["font_family"]?.string { config.fontFamily = family }
    if let cursor = table["cursor_style"]?.string { config.cursorStyle = cursor }
    if let scrollback = table["scrollback_lines"]?.int { config.scrollbackLines = scrollback }
    if let sidebar = table["sidebar_visible"]?.bool { config.sidebarVisible = sidebar }
    if let popupArray = table["popup"]?.array {
      config.popups = popupArray.compactMap { entry -> PopupDefinition? in
        guard let t = entry.table else { return nil }
        return PopupDefinition(
          name: t["name"]?.string ?? "",
          command: t["command"]?.string ?? "",
          shortcut: t["shortcut"]?.string,
          width: max(0.1, min(1.0, t["width"]?.double ?? 0.8)),
          height: max(0.1, min(1.0, t["height"]?.double ?? 0.8)),
          closeOnExit: t["close_on_exit"]?.bool ?? true
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

  static func load() -> MisttyConfig {
    let configURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
      return .default
    }
    return (try? parse(contents)) ?? .default
  }

  /// Escape a string for safe TOML serialization.
  private func tomlEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  func save() throws {
    let configURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".config/mistty/config.toml")

    try FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var lines: [String] = []
    lines.append("font_size = \(fontSize)")
    lines.append("font_family = \"\(fontFamily)\"")
    lines.append("cursor_style = \"\(cursorStyle)\"")
    lines.append("scrollback_lines = \(scrollbackLines)")
    lines.append("sidebar_visible = \(sidebarVisible)")
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
    }
    try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
  }
}
