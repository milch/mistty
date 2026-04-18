import AppKit
import CoreText
import SnapshotTesting
import SwiftUI
import XCTest

@testable import Mistty

@MainActor
final class ChromePolishSnapshotTests: XCTestCase {

  /// Register the bundled Nerd Font so `ProcessIcon` glyphs render in
  /// snapshots instead of the missing-glyph box. Matches the registration
  /// `MisttyApp` does on launch.
  private static let registerFontsOnce: Void = {
    // Walk every loaded bundle looking for the font. The Mistty target's
    // SPM resource bundle lives as a sibling of the test xctest bundle.
    for bundle in Bundle.allBundles + Bundle.allFrameworks {
      if let url = bundle.url(
        forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
      {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return
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
          return
        }
      }
    }
  }()

  /// Parks a hosting view inside a temporary offscreen window so that
  /// `List`/`.listStyle(.sidebar)` and other chrome that requires a window
  /// context will actually render instead of drawing an empty background.
  /// The window is retained by the returned helper so it stays alive for the
  /// duration of the snapshot comparison.
  @discardableResult
  private func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
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
    _ = Self.registerFontsOnce
    // Set to true to regenerate reference snapshots.
    // isRecording = true
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
}
