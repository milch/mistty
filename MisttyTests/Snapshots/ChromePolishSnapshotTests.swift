import AppKit
import CoreText
import SnapshotTesting
import SwiftUI
import XCTest

@testable import Mistty

@MainActor
final class ChromePolishSnapshotTests: XCTestCase {

  /// AppStorage keys these snapshot tests touch on UserDefaults.standard.
  /// Cleared in `tearDown` so writes don't leak into the host user's
  /// preferences or cross-contaminate between tests.
  private static let pollutedDefaultsKeys = ["sidebarVisible"]

  /// Register the bundled Nerd Font so `ProcessIcon` glyphs render in
  /// snapshots instead of the missing-glyph box. Matches the registration
  /// `MisttyApp` does on launch.
  private static let registerFontsOnce: Bool = {
    // Walk every loaded bundle looking for the font. The Mistty target's
    // SPM resource bundle lives as a sibling of the test xctest bundle.
    for bundle in Bundle.allBundles + Bundle.allFrameworks {
      if let url = bundle.url(
        forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
      {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return true
      }
    }
    // Last-ditch: look for the SPM resource bundle adjacent to the test bundle.
    let testBundleURL = Bundle(for: ChromePolishSnapshotTests.self).bundleURL
    let parent = testBundleURL.deletingLastPathComponent()
    if let entries = try? FileManager.default.contentsOfDirectory(
      at: parent, includingPropertiesForKeys: nil)
    {
      for entry in entries where entry.pathExtension == "bundle" {
        let candidate = entry.appendingPathComponent(
          "SymbolsNerdFontMono-Regular.ttf")
        if FileManager.default.fileExists(atPath: candidate.path) {
          var error: Unmanaged<CFError>?
          _ = CTFontManagerRegisterFontsForURL(
            candidate as CFURL, .process, &error)
          return true
        }
      }
    }
    return false
  }()


  /// Parks a hosting view inside a temporary offscreen window so that
  /// `List`/`.listStyle(.sidebar)` and other chrome that requires a window
  /// context will actually render instead of drawing an empty background.
  /// The window is retained by the returned helper so it stays alive for the
  /// duration of the snapshot comparison.
  @discardableResult
  private func host<V: View>(
    _ view: V,
    size: CGSize,
    appearance: NSAppearance.Name = .darkAqua
  ) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    // Pin the appearance so snapshots are stable regardless of the host's
    // current system Appearance setting.
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    // Keep the window alive for the lifetime of the hosting view. Without
    // this the window is released before the snapshot bitmap is drawn and
    // the list renders blank.
    objc_setAssociatedObject(
      hosting, &Self.windowKey, window, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return hosting
  }

  private static var windowKey: UInt8 = 0

  override func setUp() {
    super.setUp()
    XCTAssertTrue(
      Self.registerFontsOnce,
      "SymbolsNerdFontMono font not registered — snapshots would render missing glyphs")

    // Skip libghostty surface creation so the embedded terminal doesn't
    // spawn a shell whose macOS "Last login: <date>" banner makes snapshots
    // non-deterministic.
    TerminalSurfaceView.skipSurfaceCreation = true

    // Set to true to regenerate reference snapshots.
    // isRecording = true
  }

  override func tearDown() {
    TerminalSurfaceView.skipSurfaceCreation = false
    // Don't leak AppStorage writes into the host user's preferences.
    for key in Self.pollutedDefaultsKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  // MARK: - Tab bar

  func test_tabBar_threeTabs_secondActive() {
    let store = SessionStore()
    let session = store.createSession(
      name: "mistty", directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    session.addTab()
    session.addTab()
    let tabs = session.tabs
    tabs[0].title = "zsh"
    tabs[1].title = "nvim — mistty"
    tabs[2].title = "claude"
    session.activeTab = tabs[1]

    let view = TabBarView(session: session)
      .frame(width: 600, height: 28)
      .background(Color.black)

    assertSnapshot(
      of: host(view, size: CGSize(width: 600, height: 28)),
      as: .image(size: CGSize(width: 600, height: 28)),
      named: "tab-bar-3-tabs-dark"
    )
  }

  // MARK: - Sidebar row

  func test_sidebar_sessionRow_withProcessIcon() {
    let store = SessionStore()
    let session = store.createSession(
      name: "mistty", directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    session.activeTab?.activePane?.processTitle = "nvim"
    store.activeSession = session

    let view = SidebarView(store: store, width: .constant(220))
      .frame(width: 220, height: 200)
      .background(Color(NSColor.windowBackgroundColor))

    assertSnapshot(
      of: host(view, size: CGSize(width: 220, height: 200)),
      as: .image(size: CGSize(width: 220, height: 200)),
      named: "sidebar-session-row-nvim"
    )
  }

  func test_sidebar_sessionRow_withProcessIcon_lightMode() {
    // Spot-check that the sidebar styling still reads correctly in light
    // mode. The bulk of the matrix is darkAqua-only; this is the foothold
    // for parametrizing more views over both appearances later.
    let store = SessionStore()
    let session = store.createSession(
      name: "mistty", directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    session.activeTab?.activePane?.processTitle = "nvim"
    store.activeSession = session

    let view = SidebarView(store: store, width: .constant(220))
      .frame(width: 220, height: 200)
      .background(Color(NSColor.windowBackgroundColor))

    assertSnapshot(
      of: host(view, size: CGSize(width: 220, height: 200), appearance: .aqua),
      as: .image(size: CGSize(width: 220, height: 200)),
      named: "sidebar-session-row-nvim-light"
    )
  }

  func test_sidebar_sshSession() {
    let store = SessionStore()
    let session = store.createSession(
      name: "prod", directory: FileManager.default.homeDirectoryForCurrentUser)
    session.sshCommand = "ssh manu@prod.example.com"
    store.activeSession = session

    let view = SidebarView(store: store, width: .constant(220))
      .frame(width: 220, height: 200)
      .background(Color(NSColor.windowBackgroundColor))

    assertSnapshot(
      of: host(view, size: CGSize(width: 220, height: 200)),
      as: .image(size: CGSize(width: 220, height: 200)),
      named: "sidebar-ssh-row"
    )
  }

  // MARK: - Session manager

  func test_sessionManager_mixedItems() async {
    let store = SessionStore()
    let s1 = store.createSession(
      name: "running", directory: URL(fileURLWithPath: "/Users/me/Developer/other"))
    let s2 = store.createSession(
      name: "active-ignored", directory: URL(fileURLWithPath: "/Users/me/active"))
    store.activeSession = s2  // hides s2 from the session manager
    _ = s1

    let vm = SessionManagerViewModel(store: store)
    await vm.load()

    let view = SessionManagerView(
      vm: vm, isPresented: .constant(true)
    )
    .frame(width: 560, height: 400)

    assertSnapshot(
      of: host(view, size: CGSize(width: 560, height: 400)),
      as: .image(size: CGSize(width: 560, height: 400)),
      named: "session-manager-mixed"
    )
  }

  // MARK: - Full window

  func test_contentView_fullWindow() {
    UserDefaults.standard.set(true, forKey: "sidebarVisible")

    let store = SessionStore()

    // First session: two tabs so the tab bar is visible.
    let s1 = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    s1.activeTab?.activePane?.processTitle = "nvim"
    s1.activeTab?.title = "nvim — mistty"
    s1.addTab()
    s1.tabs.last?.title = "zsh"
    s1.tabs.last?.activePane?.processTitle = "zsh"
    s1.activeTab = s1.tabs.first

    // Second session: SSH, single tab (tab bar hides when active there).
    let s2 = store.createSession(
      name: "prod",
      directory: FileManager.default.homeDirectoryForCurrentUser)
    s2.sshCommand = "ssh manu@prod.example.com"

    // Point back to the first session so the snapshot shows the tab bar.
    store.activeSession = s1

    let view = ContentView(store: store, config: .default)
      .frame(width: 1200, height: 800)

    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: "content-view-full-window"
    )
  }

  func test_contentView_sidebarOpen_singleTab() {
    UserDefaults.standard.set(true, forKey: "sidebarVisible")

    let store = SessionStore()
    let s1 = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    s1.activeTab?.activePane?.processTitle = "nvim"
    s1.activeTab?.title = "nvim — mistty"

    let s2 = store.createSession(
      name: "prod",
      directory: FileManager.default.homeDirectoryForCurrentUser)
    s2.sshCommand = "ssh manu@prod.example.com"

    store.activeSession = s1  // s1 has 1 tab → tab bar hidden

    let view = ContentView(store: store, config: .default)
      .frame(width: 1200, height: 800)

    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: "content-view-sidebar-open-single-tab"
    )
  }

  func test_contentView_sidebarClosed_singleTab() {
    UserDefaults.standard.set(false, forKey: "sidebarVisible")

    let store = SessionStore()
    let s1 = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    s1.activeTab?.activePane?.processTitle = "nvim"
    s1.activeTab?.title = "nvim — mistty"

    store.activeSession = s1

    let view = ContentView(store: store, config: .default)
      .frame(width: 1200, height: 800)

    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: "content-view-sidebar-closed-single-tab"
    )
  }

  // MARK: - Popup overlay
  //
  // Regression guard for: backdrop nested inside `PopupOverlayView`.
  // When the backdrop lived inside the popup view it inherited the popup
  // chrome's frame (~80% of the window), so its sharp 90° corners were
  // visible adjacent to the rounded chrome — looked like the popup itself
  // had black/sharp corners. The backdrop must sit at the same level as
  // the popup chrome (in `ContentView.popupOverlay`) so it covers the
  // whole window. This snapshot will diff loudly if anyone moves the
  // backdrop back inside the popup view.
  func test_contentView_popupActive() {
    UserDefaults.standard.set(true, forKey: "sidebarVisible")

    let store = SessionStore()
    let session = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    session.activeTab?.activePane?.processTitle = "nvim"
    session.activeTab?.title = "nvim — mistty"
    store.activeSession = session

    session.openPopup(definition: PopupDefinition(
      name: "Quick Command", command: "echo hi"))

    let view = ContentView(store: store, config: .default)
      .frame(width: 1200, height: 800)

    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: "content-view-popup-active"
    )
  }

  func test_contentView_sidebarClosed_multipleTabs() {
    UserDefaults.standard.set(false, forKey: "sidebarVisible")

    let store = SessionStore()
    let s1 = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    s1.activeTab?.activePane?.processTitle = "nvim"
    s1.activeTab?.title = "nvim — mistty"
    s1.addTab()
    s1.tabs.last?.title = "zsh"
    s1.tabs.last?.activePane?.processTitle = "zsh"
    s1.activeTab = s1.tabs.first

    store.activeSession = s1

    let view = ContentView(store: store, config: .default)
      .frame(width: 1200, height: 800)

    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: "content-view-sidebar-closed-multi-tab"
    )
  }

  // MARK: - Matrix (TabBarMode x TitleBarStyle)

  func test_matrix_always_always() {
    assertMatrix(tabBarMode: .always, titleBarStyle: .always, testName: #function)
  }
  func test_matrix_always_hiddenWithLights() {
    assertMatrix(tabBarMode: .always, titleBarStyle: .hiddenWithLights, testName: #function)
  }
  func test_matrix_always_hiddenNoLights() {
    assertMatrix(tabBarMode: .always, titleBarStyle: .hiddenNoLights, testName: #function)
  }

  func test_matrix_never_always() {
    assertMatrix(tabBarMode: .never, titleBarStyle: .always, testName: #function)
  }
  func test_matrix_never_hiddenWithLights() {
    assertMatrix(tabBarMode: .never, titleBarStyle: .hiddenWithLights, testName: #function)
  }
  func test_matrix_never_hiddenNoLights() {
    assertMatrix(tabBarMode: .never, titleBarStyle: .hiddenNoLights, testName: #function)
  }

  func test_matrix_whenSidebarHidden_always() {
    assertMatrix(tabBarMode: .whenSidebarHidden, titleBarStyle: .always, testName: #function)
  }
  func test_matrix_whenSidebarHidden_hiddenWithLights() {
    assertMatrix(
      tabBarMode: .whenSidebarHidden, titleBarStyle: .hiddenWithLights, testName: #function)
  }
  func test_matrix_whenSidebarHidden_hiddenNoLights() {
    assertMatrix(
      tabBarMode: .whenSidebarHidden, titleBarStyle: .hiddenNoLights, testName: #function)
  }

  func test_matrix_whenSidebarHiddenAndMultipleTabs_always() {
    assertMatrix(
      tabBarMode: .whenSidebarHiddenAndMultipleTabs, titleBarStyle: .always, testName: #function)
  }
  func test_matrix_whenSidebarHiddenAndMultipleTabs_hiddenWithLights() {
    assertMatrix(
      tabBarMode: .whenSidebarHiddenAndMultipleTabs, titleBarStyle: .hiddenWithLights,
      testName: #function)
  }
  func test_matrix_whenSidebarHiddenAndMultipleTabs_hiddenNoLights() {
    assertMatrix(
      tabBarMode: .whenSidebarHiddenAndMultipleTabs, titleBarStyle: .hiddenNoLights,
      testName: #function)
  }

  func test_matrix_whenMultipleTabs_always() {
    assertMatrix(tabBarMode: .whenMultipleTabs, titleBarStyle: .always, testName: #function)
  }
  func test_matrix_whenMultipleTabs_hiddenWithLights() {
    assertMatrix(
      tabBarMode: .whenMultipleTabs, titleBarStyle: .hiddenWithLights, testName: #function)
  }
  func test_matrix_whenMultipleTabs_hiddenNoLights() {
    assertMatrix(
      tabBarMode: .whenMultipleTabs, titleBarStyle: .hiddenNoLights, testName: #function)
  }

  // MARK: - Matrix helpers

  private func assertMatrix(
    tabBarMode: TabBarMode,
    titleBarStyle: TitleBarStyle,
    testName: String,
    filePath: StaticString = #filePath,
    line: UInt = #line
  ) {
    UserDefaults.standard.set(true, forKey: "sidebarVisible")

    let store = SessionStore()
    let s1 = store.createSession(
      name: "mistty",
      directory: URL(fileURLWithPath: "/Users/me/Developer/mistty"))
    s1.activeTab?.activePane?.processTitle = "nvim"
    s1.activeTab?.title = "nvim — mistty"
    s1.addTab()
    s1.tabs[1].title = "zsh"
    s1.tabs[1].activePane?.processTitle = "zsh"
    s1.addTab()
    s1.tabs[2].title = "claude"
    s1.tabs[2].activePane?.processTitle = "claude"
    s1.activeTab = s1.tabs[1]

    let s2 = store.createSession(
      name: "prod",
      directory: FileManager.default.homeDirectoryForCurrentUser)
    s2.sshCommand = "ssh manu@prod.example.com"

    store.activeSession = s1

    var ui = UIConfig()
    ui.tabBarMode = tabBarMode
    ui.titleBarStyle = titleBarStyle
    var cfg = MisttyConfig.default
    cfg.ui = ui

    let view =
      ContentView(store: store, config: cfg)
      .applyTopSafeArea(style: titleBarStyle)
      .overlay(alignment: .topLeading) {
        chromeOverlay(style: titleBarStyle)
      }
      .frame(width: 1200, height: 800)

    let snapshotName = "matrix-\(tabBarMode.rawValue)-\(titleBarStyle.rawValue)"
    assertSnapshot(
      of: host(view, size: CGSize(width: 1200, height: 800)),
      as: .image(size: CGSize(width: 1200, height: 800)),
      named: snapshotName,
      file: filePath,
      testName: testName,
      line: line
    )
  }

  @ViewBuilder
  private func chromeOverlay(style: TitleBarStyle) -> some View {
    switch style {
    case .always:
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(Color(NSColor.windowBackgroundColor))
          .frame(height: 28)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
          }
        HStack(spacing: 8) {
          Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
          Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
          Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
        }
        .padding(.leading, 10)
      }
      .frame(maxWidth: .infinity)
    case .hiddenWithLights:
      HStack(spacing: 8) {
        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
      }
      .padding(.leading, 10)
      .padding(.top, 10)
      .allowsHitTesting(false)
    case .hiddenNoLights:
      Color.clear
    }
  }
}
