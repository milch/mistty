import SwiftUI

struct ContentView: View {
    @State var store = SessionStore()
    @AppStorage("sidebarVisible") var sidebarVisible = true
    @State var showingSessionManager = false

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(store: store)
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
                            activePane: tab.activePane
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
            if showingSessionManager {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showingSessionManager = false }

                SessionManagerView(
                    vm: SessionManagerViewModel(store: store),
                    isPresented: $showingSessionManager
                )
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
    }
}
