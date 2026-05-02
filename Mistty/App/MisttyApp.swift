import CoreText
import Foundation
import GhosttyKit
import MisttyShared
import SwiftUI

@main
struct MisttyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var windowsStore = WindowsStore()
  @State private var ipcListener: IPCListener?
  @AppStorage("sidebarVisible") var sidebarVisible = true
  // Shared parse — see `MisttyConfig.current`. Reading the same cache
  // GhosttyAppManager uses keeps SwiftUI state and libghostty in lockstep and
  // avoids parsing the TOML twice at bootstrap.
  @State private var config: MisttyConfig = MisttyConfig.current

  init() {
    // Opt in to AppKit state restoration by default. Without this, macOS 14+
    // defaults to clearing saved state on quit (the OS-level "Close windows
    // when quitting an app" default), which defeats our restoration feature
    // out of the box. Users who explicitly set `NSQuitAlwaysKeepsWindows =
    // NO` in defaults still win — register() only fills in when no value is
    // set by the user or the system.
    UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])

    _ = GhosttyAppManager.shared
    Self.registerBundledFonts()
    DebugLog.shared.configure(enabled: config.debugLogging)
    DebugLog.shared.log("restore", "MisttyApp.init")
    appDelegate.windowsStore = _windowsStore.wrappedValue
    appDelegate.observer = StateRestorationObserver(windowsStore: _windowsStore.wrappedValue)
  }

  private static func registerBundledFonts() {
    guard
      let url = Bundle.main.url(
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
    WindowGroup(id: "terminal") {
      WindowRootView(windowsStore: windowsStore, config: config)
        .applyTopSafeArea(style: config.ui.titleBarStyle)
        .onAppear {
          if ipcListener == nil {
            let service = MisttyIPCService(windowsStore: windowsStore)
            let listener = IPCListener(service: service)
            listener.start()
            ipcListener = listener
          }
          applyTitleBarStyleToWindows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyConfigDidReload)) { _ in
          config = MisttyConfig.current
          applyTitleBarStyleToWindows()
          DebugLog.shared.configure(enabled: config.debugLogging)
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyReloadConfig)) { _ in
          do {
            try MisttyConfig.reload()
          } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Mistty could not reload config.toml"
            alert.informativeText =
              "\(describeTOMLParseError(error))\n\nFile: \(MisttyConfig.configURL.path)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyReopenClosedWindow)) { _ in
          guard let _ = windowsStore.reopenMostRecentClosed() else {
            NSSound.beep()
            return
          }
          windowsStore.openWindowAction?(id: "terminal")
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .toolbar) {
        Divider()

        kbShortcut(
          .toggleSidebar,
          on: Button("Toggle Sidebar") {
            NotificationCenter.default.post(name: .misttyToggleSidebar, object: nil)
          }
        )

        kbShortcut(
          .toggleTabBar,
          on: Button("Toggle Tab Bar") {
            NotificationCenter.default.post(name: .misttyToggleTabBar, object: nil)
          }
        )

        kbShortcut(
          .reloadConfig,
          on: Button("Reload Config") {
            NotificationCenter.default.post(name: .misttyReloadConfig, object: nil)
          }
        )

        kbShortcut(
          .newTab,
          on: Button("New Tab") {
            NotificationCenter.default.post(name: .misttyNewTab, object: nil)
          }
        )

        kbShortcut(
          .newTabPlain,
          on: Button("New Tab (Plain)") {
            NotificationCenter.default.post(name: .misttyNewTabPlain, object: nil)
          }
        )

        kbShortcut(
          .splitHorizontal,
          on: Button("Split Pane Horizontally") {
            NotificationCenter.default.post(name: .misttySplitHorizontal, object: nil)
          }
        )

        kbShortcut(
          .splitHorizontalPlain,
          on: Button("Split Pane Horizontally (Plain)") {
            NotificationCenter.default.post(name: .misttySplitHorizontalPlain, object: nil)
          }
        )

        kbShortcut(
          .splitVertical,
          on: Button("Split Pane Vertically") {
            NotificationCenter.default.post(name: .misttySplitVertical, object: nil)
          }
        )

        kbShortcut(
          .splitVerticalPlain,
          on: Button("Split Pane Vertically (Plain)") {
            NotificationCenter.default.post(name: .misttySplitVerticalPlain, object: nil)
          }
        )

        kbShortcut(
          .sessionManager,
          on: Button("Session Manager") {
            NotificationCenter.default.post(name: .misttySessionManager, object: nil)
          }
        )

        Divider()

        kbShortcut(
          .closePane,
          on: Button("Close Pane") {
            // If a non-terminal window (e.g. Settings) is key, let the system
            // close that window instead of routing the shortcut to the terminal.
            if windowsStore.isTerminalWindowKey() {
              DebugLog.shared.log("cmdw", "menu Close Pane → posting notification")
              NotificationCenter.default.post(name: .misttyClosePane, object: nil)
            } else {
              DebugLog.shared.log(
                "cmdw",
                "menu Close Pane → performClose on keyWindow=\(NSApp.keyWindow.map { "num=\($0.windowNumber) title=\"\($0.title)\"" } ?? "nil")"
              )
              NSApp.keyWindow?.performClose(nil)
            }
          }
        )

        kbShortcut(
          .closeTab,
          on: Button("Close Tab") {
            if windowsStore.isTerminalWindowKey() {
              DebugLog.shared.log("cmdw", "menu Close Tab → posting notification")
              NotificationCenter.default.post(name: .misttyCloseTab, object: nil)
            } else {
              DebugLog.shared.log(
                "cmdw",
                "menu Close Tab → performClose on keyWindow=\(NSApp.keyWindow.map { "num=\($0.windowNumber) title=\"\($0.title)\"" } ?? "nil")"
              )
              NSApp.keyWindow?.performClose(nil)
            }
          }
        )

        kbShortcut(
          .closeWindow,
          on: Button("Close Window") {
            if windowsStore.isTerminalWindowKey() {
              DebugLog.shared.log("cmdw", "menu Close Window → posting notification")
              NotificationCenter.default.post(name: .misttyCloseWindow, object: nil)
            } else {
              NSApp.keyWindow?.performClose(nil)
            }
          }
        )

        kbShortcut(
          .reopenClosedWindow,
          on: Button("Reopen Closed Window") {
            NotificationCenter.default.post(name: .misttyReopenClosedWindow, object: nil)
          }
        )

        kbShortcut(
          .windowMode,
          on: Button("Window Mode") {
            NotificationCenter.default.post(name: .misttyWindowMode, object: nil)
          }
        )

        kbShortcut(
          .copyMode,
          on: Button("Copy Mode") {
            NotificationCenter.default.post(name: .misttyCopyMode, object: nil)
          }
        )

        kbShortcut(
          .yankHints,
          on: Button("Yank Hints") {
            NotificationCenter.default.post(name: .misttyYankHints, object: nil)
          }
        )

        Divider()

        kbShortcut(
          .renameTab,
          on: Button("Rename Tab") {
            NotificationCenter.default.post(name: .misttyRenameTab, object: nil)
          }
        )

        kbShortcut(
          .renameSession,
          on: Button("Rename Session") {
            NotificationCenter.default.post(name: .misttyRenameSession, object: nil)
          }
        )

        Divider()

        ForEach(1...9, id: \.self) { index in
          Button("Focus Tab \(index)") {
            NotificationCenter.default.post(
              name: .misttyFocusTabByIndex,
              object: nil,
              userInfo: ["index": index - 1]
            )
          }
          .keyboardShortcut(
            KeyEquivalent(Character("\(index)")),
            modifiers: eventModifiers(from: config.shortcuts.tabIndexModifier))
        }

        ForEach(1...9, id: \.self) { index in
          Button("Focus Session \(index)") {
            NotificationCenter.default.post(
              name: .misttyFocusSessionByIndex,
              object: nil,
              userInfo: ["index": index - 1]
            )
          }
          .keyboardShortcut(
            KeyEquivalent(Character("\(index)")),
            modifiers: eventModifiers(from: config.shortcuts.sessionIndexModifier))
        }

        kbShortcut(
          .nextTab,
          on: Button("Next Tab") {
            NotificationCenter.default.post(name: .misttyNextTab, object: nil)
          }
        )

        kbShortcut(
          .prevTab,
          on: Button("Previous Tab") {
            NotificationCenter.default.post(name: .misttyPrevTab, object: nil)
          }
        )

        kbShortcut(
          .prevSession,
          on: Button("Previous Session") {
            NotificationCenter.default.post(name: .misttyPrevSession, object: nil)
          }
        )

        kbShortcut(
          .nextSession,
          on: Button("Next Session") {
            NotificationCenter.default.post(name: .misttyNextSession, object: nil)
          }
        )

        kbShortcut(
          .swapSessionUp,
          on: Button("Move Session Up") {
            NotificationCenter.default.post(name: .misttyMoveSessionUp, object: nil)
          }
        )

        kbShortcut(
          .swapSessionDown,
          on: Button("Move Session Down") {
            NotificationCenter.default.post(name: .misttyMoveSessionDown, object: nil)
          }
        )

        Divider()

        ForEach(Array(config.popups.enumerated()), id: \.offset) { _, popup in
          if let chord = popup.shortcutChord {
            let (key, mods) = chord.swiftUI()
            Button("Toggle \(popup.name)") {
              NotificationCenter.default.post(
                name: .misttyPopupToggle,
                object: nil,
                userInfo: ["name": popup.name]
              )
            }
            .keyboardShortcut(key, modifiers: mods)
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

  @ViewBuilder
  private func kbShortcut<V: View>(
    _ action: ShortcutAction, on view: V
  ) -> some View {
    if let chord = config.shortcuts.primary(for: action) {
      let (key, mods) = chord.swiftUI()
      view.keyboardShortcut(key, modifiers: mods)
    } else {
      view
    }
  }

  private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
    var m: EventModifiers = []
    if flags.contains(.command) { m.insert(.command) }
    if flags.contains(.shift)   { m.insert(.shift) }
    if flags.contains(.option)  { m.insert(.option) }
    if flags.contains(.control) { m.insert(.control) }
    return m
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
  static let misttyNewTabPlain = Notification.Name("misttyNewTabPlain")
  static let misttySplitHorizontal = Notification.Name("misttySplitHorizontal")
  static let misttySplitHorizontalPlain = Notification.Name("misttySplitHorizontalPlain")
  static let misttySplitVertical = Notification.Name("misttySplitVertical")
  static let misttySplitVerticalPlain = Notification.Name("misttySplitVerticalPlain")
  static let misttySessionManager = Notification.Name("misttySessionManager")
  static let misttyClosePane = Notification.Name("misttyClosePane")
  static let misttyCloseTab = Notification.Name("misttyCloseTab")
  static let misttyCloseWindow = Notification.Name("misttyCloseWindow")
  static let misttyToggleSidebar = Notification.Name("misttyToggleSidebar")
  static let misttyToggleTabBar = Notification.Name("misttyToggleTabBar")
  static let misttyRenameTab = Notification.Name("misttyRenameTab")
  static let misttyRenameSession = Notification.Name("misttyRenameSession")
  static let misttyWindowMode = Notification.Name("misttyWindowMode")
  static let misttyCopyMode = Notification.Name("misttyCopyMode")
  static let misttyYankHints = Notification.Name("misttyYankHints")
  static let misttyPopupToggle = Notification.Name("misttyPopupToggle")
  static let misttyFocusTabByIndex = Notification.Name("misttyFocusTabByIndex")
  static let misttyFocusSessionByIndex = Notification.Name("misttyFocusSessionByIndex")
  static let misttyNextTab = Notification.Name("misttyNextTab")
  static let misttyPrevTab = Notification.Name("misttyPrevTab")
  static let misttyNextSession = Notification.Name("misttyNextSession")
  static let misttyPrevSession = Notification.Name("misttyPrevSession")
  static let misttyMoveSessionUp = Notification.Name("misttyMoveSessionUp")
  static let misttyMoveSessionDown = Notification.Name("misttyMoveSessionDown")
  static let misttyScrollChanged = Notification.Name("misttyScrollChanged")
  /// Triggered by the View → Reload Config menu item. Handled at the
  /// WindowGroup root in `body`, which calls `MisttyConfig.reload()`.
  static let misttyReloadConfig = Notification.Name("misttyReloadConfig")
  static let misttyReopenClosedWindow = Notification.Name("misttyReopenClosedWindow")
}
