import CoreText
import Foundation
import GhosttyKit
import MisttyShared
import SwiftUI

@main
struct MisttyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var windowsStore = WindowsStore()
  /// Resolves window-scoped commands to the single focused terminal window
  /// and bridges the legacy mistty* notifications into typed dispatches.
  /// Created in `init()` once `windowsStore` exists.
  @State private var commandRouter: WindowCommandRouter
  @State private var ipcListener: IPCListener?
  // Shared parse — see `MisttyConfig.current`. Reading the same cache
  // GhosttyAppManager uses keeps SwiftUI state and libghostty in lockstep and
  // avoids parsing the TOML twice at bootstrap.
  @State private var config: MisttyConfig = MisttyConfig.current

  init() {
    // Initialize the router first: it has no default value, and Swift won't
    // let `init` touch `self` (e.g. read `config`) until every stored
    // property is set. `_windowsStore`'s wrappedValue is the
    // property-initializer default, available before `init` runs.
    _commandRouter = State(
      initialValue: WindowCommandRouter(windowsStore: _windowsStore.wrappedValue))

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
    NotificationService.shared.start(windowsStore: _windowsStore.wrappedValue)
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
      WindowRootView(windowsStore: windowsStore, commandRouter: commandRouter, config: config)
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

        menuButton(.toggleSidebar, "Toggle Sidebar")
        menuButton(.toggleTabBar, "Toggle Tab Bar")
        menuButton(.reloadConfig, "Reload Config")
        menuButton(.newTab, "New Tab")
        menuButton(.newTabPlain, "New Tab (Plain)")
        menuButton(.splitHorizontal, "Split Pane Horizontally")
        menuButton(.splitHorizontalPlain, "Split Pane Horizontally (Plain)")
        menuButton(.splitVertical, "Split Pane Vertically")
        menuButton(.splitVerticalPlain, "Split Pane Vertically (Plain)")
        menuButton(.sessionManager, "Session Manager")

        Divider()

        closeMenuButton(.closePane, "Close Pane")
        closeMenuButton(.closeTab, "Close Tab")
        closeMenuButton(.closeWindow, "Close Window")
        menuButton(.reopenClosedWindow, "Reopen Closed Window")
        menuButton(.windowMode, "Window Mode")
        menuButton(.copyMode, "Copy Mode")
        menuButton(.yankHints, "Yank Hints (Copy)")
        menuButton(.yankHintsOpen, "Yank Hints (Open)")
        menuButton(.yankHintsCursor, "Yank Hints (Cursor)")

        Divider()

        menuButton(.renameTab, "Rename Tab")
        menuButton(.renameSession, "Rename Session")
        menuButton(.reparentSession, "Change Session Directory…")

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
            modifiers: config.shortcuts.tabIndexModifier.swiftUIModifiers)
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
            modifiers: config.shortcuts.sessionIndexModifier.swiftUIModifiers)
        }

        menuButton(.nextTab, "Next Tab")
        menuButton(.prevTab, "Previous Tab")
        menuButton(.prevSession, "Previous Session")
        menuButton(.nextSession, "Next Session")
        menuButton(.swapSessionUp, "Move Session Up")
        menuButton(.swapSessionDown, "Move Session Down")

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

  /// Standard menu item: title + post the action's notification, with the
  /// user-configured shortcut attached. Replaces 20+ hand-written
  /// Button/post/kbShortcut triples that re-encoded the action→notification
  /// mapping ShortcutAction.notificationName already owns.
  @ViewBuilder
  private func menuButton(_ action: ShortcutAction, _ title: String) -> some View {
    kbShortcut(
      action,
      on: Button(title) {
        NotificationCenter.default.post(name: action.notificationName, object: nil)
      }
    )
  }

  /// Close Pane/Tab/Window share a guard: when a non-terminal window
  /// (e.g. Settings) is key, let the system close that window instead of
  /// routing the shortcut to the terminal.
  @ViewBuilder
  private func closeMenuButton(_ action: ShortcutAction, _ title: String) -> some View {
    kbShortcut(
      action,
      on: Button(title) {
        if windowsStore.isTerminalWindowKey() {
          DebugLog.shared.log("cmdw", "menu \(title) → posting notification")
          NotificationCenter.default.post(name: action.notificationName, object: nil)
        } else {
          DebugLog.shared.log(
            "cmdw",
            "menu \(title) → performClose on keyWindow=\(NSApp.keyWindow.map { "num=\($0.windowNumber) title=\"\($0.title)\"" } ?? "nil")"
          )
          NSApp.keyWindow?.performClose(nil)
        }
      }
    )
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
  static let misttyReparentSession = Notification.Name("misttyReparentSession")
  static let misttyWindowMode = Notification.Name("misttyWindowMode")
  static let misttyCopyMode = Notification.Name("misttyCopyMode")
  static let misttyYankHints = Notification.Name("misttyYankHints")
  static let misttyYankHintsOpen = Notification.Name("misttyYankHintsOpen")
  static let misttyYankHintsCursor = Notification.Name("misttyYankHintsCursor")
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
