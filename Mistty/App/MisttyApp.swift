import CoreText
import Foundation
import GhosttyKit
import SwiftUI

@main
struct MisttyApp: App {
  @State private var store = SessionStore()
  @State private var ipcListener: IPCListener?
  @AppStorage("sidebarVisible") var sidebarVisible = true
  @AppStorage("tabBarOverride") var tabBarOverrideRaw = TabBarVisibilityOverride.auto.rawValue
  // Shared parse — see `MisttyConfig.loadedAtLaunch`. Reading the same cache
  // GhosttyAppManager uses keeps SwiftUI state and libghostty in lockstep and
  // avoids parsing the TOML twice at bootstrap.
  private let config: MisttyConfig = MisttyConfig.loadedAtLaunch.config

  init() {
    _ = GhosttyAppManager.shared
    Self.registerBundledFonts()
  }

  private static func registerBundledFonts() {
    guard
      let url = Bundle.module.url(
        forResource: "SymbolsNerdFontMono-Regular",
        withExtension: "ttf")
    else {
      NSLog("[Mistty] SymbolsNerdFontMono-Regular.ttf missing from bundle")
      return
    }
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
      let err = error?.takeRetainedValue()
      NSLog("[Mistty] Failed to register bundled Nerd Font: \(String(describing: err))")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: store, config: config)
        .applyTopSafeArea(style: config.ui.titleBarStyle)
        .onAppear {
          if ipcListener == nil {
            let service = MisttyIPCService(store: store)
            let listener = IPCListener(service: service)
            listener.start()
            ipcListener = listener
          }
          applyTitleBarStyleToWindows()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .toolbar) {
        Divider()

        Button("Toggle Sidebar") {
          withAnimation(.easeInOut(duration: 0.18)) {
            sidebarVisible.toggle()
          }
        }
        .keyboardShortcut("s", modifiers: .command)

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

        Button("New Tab") {
          NotificationCenter.default.post(name: .misttyNewTab, object: nil)
        }
        .keyboardShortcut("t", modifiers: .command)

        Button("Split Pane Horizontally") {
          NotificationCenter.default.post(name: .misttySplitHorizontal, object: nil)
        }
        .keyboardShortcut("d", modifiers: .command)

        Button("Split Pane Vertically") {
          NotificationCenter.default.post(name: .misttySplitVertical, object: nil)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Button("Session Manager") {
          NotificationCenter.default.post(name: .misttySessionManager, object: nil)
        }
        .keyboardShortcut("j", modifiers: .command)

        Divider()

        Button("Close Pane") {
          // If a non-terminal window (e.g. Settings) is key, let the system
          // close that window instead of routing the shortcut to the terminal.
          if store.isTerminalWindowKey() {
            NotificationCenter.default.post(name: .misttyClosePane, object: nil)
          } else {
            NSApp.keyWindow?.performClose(nil)
          }
        }
        .keyboardShortcut("w", modifiers: .command)

        Button("Close Tab") {
          if store.isTerminalWindowKey() {
            NotificationCenter.default.post(name: .misttyCloseTab, object: nil)
          } else {
            NSApp.keyWindow?.performClose(nil)
          }
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])

        Button("Window Mode") {
          NotificationCenter.default.post(name: .misttyWindowMode, object: nil)
        }
        .keyboardShortcut("x", modifiers: .command)

        Button("Copy Mode") {
          NotificationCenter.default.post(name: .misttyCopyMode, object: nil)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Button("Yank Hints") {
          NotificationCenter.default.post(name: .misttyYankHints, object: nil)
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])

        Divider()

        Button("Rename Tab") {
          NotificationCenter.default.post(name: .misttyRenameTab, object: nil)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        ForEach(1...9, id: \.self) { index in
          Button("Focus Tab \(index)") {
            NotificationCenter.default.post(
              name: .misttyFocusTabByIndex,
              object: nil,
              userInfo: ["index": index - 1]
            )
          }
          .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
        }

        Button("Next Tab") {
          NotificationCenter.default.post(name: .misttyNextTab, object: nil)
        }
        .keyboardShortcut("]", modifiers: .command)

        Button("Previous Tab") {
          NotificationCenter.default.post(name: .misttyPrevTab, object: nil)
        }
        .keyboardShortcut("[", modifiers: .command)

        Button("Previous Session") {
          NotificationCenter.default.post(name: .misttyPrevSession, object: nil)
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

        Button("Next Session") {
          NotificationCenter.default.post(name: .misttyNextSession, object: nil)
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .shift])

        Divider()

        ForEach(Array(config.popups.enumerated()), id: \.offset) { _, popup in
          if let key = parseShortcutKey(popup.shortcut),
            let modifiers = parseShortcutModifiers(popup.shortcut)
          {
            Button("Toggle \(popup.name)") {
              NotificationCenter.default.post(
                name: .misttyPopupToggle,
                object: nil,
                userInfo: ["name": popup.name]
              )
            }
            .keyboardShortcut(key, modifiers: modifiers)
          }
        }
      }
    }

    Settings {
      SettingsView()
    }
  }

  /// Apply the configured `TitleBarStyle` to every NSWindow. We always
  /// declare `.windowStyle(.hiddenTitleBar)` at the Scene level (SwiftUI
  /// `SceneBuilder` can't branch over window styles) and then adjust the
  /// AppKit windows here to realize each style.
  private func applyTitleBarStyleToWindows() {
    let style = config.ui.titleBarStyle
    DispatchQueue.main.async {
      for window in NSApplication.shared.windows {
        switch style {
        case .always:
          // Show a standard title bar: visible title, no transparent
          // titlebar, content does NOT extend under the title bar.
          window.titleVisibility = .visible
          window.titlebarAppearsTransparent = false
          window.styleMask.remove(.fullSizeContentView)
          window.standardWindowButton(.closeButton)?.isHidden = false
          window.standardWindowButton(.miniaturizeButton)?.isHidden = false
          window.standardWindowButton(.zoomButton)?.isHidden = false
        case .hiddenWithLights:
          window.titleVisibility = .hidden
          window.titlebarAppearsTransparent = true
          window.styleMask.insert(.fullSizeContentView)
          window.standardWindowButton(.closeButton)?.isHidden = false
          window.standardWindowButton(.miniaturizeButton)?.isHidden = false
          window.standardWindowButton(.zoomButton)?.isHidden = false
        case .hiddenNoLights:
          window.titleVisibility = .hidden
          window.titlebarAppearsTransparent = true
          window.styleMask.insert(.fullSizeContentView)
          window.standardWindowButton(.closeButton)?.isHidden = true
          window.standardWindowButton(.miniaturizeButton)?.isHidden = true
          window.standardWindowButton(.zoomButton)?.isHidden = true
        }
      }
    }
  }

  /// Normalize shortcut string: lowercase, accept both "+" and "-" as separators.
  private func shortcutParts(_ shortcut: String?) -> [Substring]? {
    guard let shortcut else { return nil }
    let normalized = shortcut.lowercased().replacing("-", with: "+")
    let parts = normalized.split(separator: "+")
    return parts.isEmpty ? nil : parts
  }

  private func parseShortcutKey(_ shortcut: String?) -> KeyEquivalent? {
    guard let parts = shortcutParts(shortcut),
      let last = parts.last, last.count == 1, let char = last.first
    else { return nil }
    return KeyEquivalent(char)
  }

  private func parseShortcutModifiers(_ shortcut: String?) -> EventModifiers? {
    guard let parts = shortcutParts(shortcut) else { return nil }
    var modifiers: EventModifiers = []
    for part in parts.dropLast() {
      switch part {
      case "cmd", "command": modifiers.insert(.command)
      case "shift": modifiers.insert(.shift)
      case "opt", "option", "alt": modifiers.insert(.option)
      case "ctrl", "control": modifiers.insert(.control)
      default: break
      }
    }
    return modifiers.isEmpty ? nil : modifiers
  }
}

extension View {
  @ViewBuilder
  func applyTopSafeArea(style: TitleBarStyle) -> some View {
    if style.contentExtendsUnderTitleBar {
      self.ignoresSafeArea(.container, edges: .top)
    } else {
      self
    }
  }
}

extension Notification.Name {
  static let misttyNewTab = Notification.Name("misttyNewTab")
  static let misttySplitHorizontal = Notification.Name("misttySplitHorizontal")
  static let misttySplitVertical = Notification.Name("misttySplitVertical")
  static let misttySessionManager = Notification.Name("misttySessionManager")
  static let misttyClosePane = Notification.Name("misttyClosePane")
  static let misttyCloseTab = Notification.Name("misttyCloseTab")
  static let misttyRenameTab = Notification.Name("misttyRenameTab")
  static let misttyWindowMode = Notification.Name("misttyWindowMode")
  static let misttyCopyMode = Notification.Name("misttyCopyMode")
  static let misttyYankHints = Notification.Name("misttyYankHints")
  static let misttyPopupToggle = Notification.Name("misttyPopupToggle")
  static let misttyFocusTabByIndex = Notification.Name("misttyFocusTabByIndex")
  static let misttyNextTab = Notification.Name("misttyNextTab")
  static let misttyPrevTab = Notification.Name("misttyPrevTab")
  static let misttyNextSession = Notification.Name("misttyNextSession")
  static let misttyPrevSession = Notification.Name("misttyPrevSession")
  static let misttyScrollChanged = Notification.Name("misttyScrollChanged")
}
