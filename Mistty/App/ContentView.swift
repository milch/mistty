import AppKit
import SwiftUI

struct ContentView: View {
    @State var store = SessionStore()
    @AppStorage("sidebarVisible") var sidebarVisible = true
    @SceneStorage("sidebarWidth") var sidebarWidth: Double = 220
    @State var showingSessionManager = false
    @State private var sessionManagerVM: SessionManagerViewModel?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(store: store, width: Binding(
                    get: { CGFloat(sidebarWidth) },
                    set: { sidebarWidth = Double($0) }
                ))
                Divider()
            }

            Group {
                if let session = store.activeSession,
                   let tab = session.activeTab {
                    VStack(spacing: 0) {
                        TabBarView(session: session)
                        Divider()
                        PaneLayoutView(
                            node: tab.layout.root,
                            activePane: tab.activePane,
                            onClosePane: { pane in closePane(pane) },
                            onSelectPane: { pane in tab.activePane = pane }
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("No active session")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Press ⌘J to open or create a session")
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay {
            if showingSessionManager, let vm = sessionManagerVM {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showingSessionManager = false }

                SessionManagerView(
                    vm: vm,
                    isPresented: $showingSessionManager
                )
            }
        }
        .onChange(of: showingSessionManager) { _, isShowing in
            if isShowing {
                let vm = SessionManagerViewModel(store: store)
                sessionManagerVM = vm
                installKeyMonitor(vm: vm)
            } else {
                removeKeyMonitor()
                sessionManagerVM = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyNewTab)) { _ in
            store.activeSession?.addTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mistrySplitHorizontal)) { _ in
            store.activeSession?.activeTab?.splitActivePane(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mistrySplitVertical)) { _ in
            store.activeSession?.activeTab?.splitActivePane(direction: .vertical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttySessionManager)) { _ in
            showingSessionManager = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyClosePane)) { _ in
            guard let tab = store.activeSession?.activeTab,
                  let pane = tab.activePane else { return }
            closePane(pane)
        }
        .onReceive(NotificationCenter.default.publisher(for: .misttyCloseTab)) { _ in
            guard let session = store.activeSession,
                  let tab = session.activeTab else { return }
            session.closeTab(tab)
            if session.tabs.isEmpty {
                store.closeSession(session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySetTitle)) { notification in
            guard let paneID = notification.userInfo?["paneID"] as? UUID,
                  let title = notification.userInfo?["title"] as? String else { return }
            // Find the tab containing this pane and update its title
            for session in store.sessions {
                for tab in session.tabs {
                    if tab.panes.contains(where: { $0.id == paneID }) {
                        tab.title = title
                        return
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyCloseSurface)) { notification in
            guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
            // Find and close the pane whose shell exited
            for session in store.sessions {
                for tab in session.tabs {
                    if let pane = tab.panes.first(where: { $0.id == paneID }) {
                        closePaneInTab(pane, tab: tab, session: session)
                        return
                    }
                }
            }
        }
    }

    private func closePane(_ pane: MisttyPane) {
        guard let session = store.activeSession,
              let tab = session.activeTab else { return }
        closePaneInTab(pane, tab: tab, session: session)
    }

    private func closePaneInTab(_ pane: MisttyPane, tab: MisttyTab, session: MisttySession) {
        tab.closePane(pane)
        if tab.panes.isEmpty {
            session.closeTab(tab)
            if session.tabs.isEmpty {
                store.closeSession(session)
            }
        }
    }

    private func installKeyMonitor(vm: SessionManagerViewModel) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Escape
                showingSessionManager = false
                return nil
            case 36: // Return
                vm.confirmSelection()
                showingSessionManager = false
                return nil
            case 126: // Up arrow
                vm.moveUp()
                return nil
            case 125: // Down arrow
                vm.moveDown()
                return nil
            default:
                break
            }

            if event.modifierFlags.contains(.control) {
                if event.charactersIgnoringModifiers == "j" {
                    vm.moveDown()
                    return nil
                } else if event.charactersIgnoringModifiers == "k" {
                    vm.moveUp()
                    return nil
                }
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
