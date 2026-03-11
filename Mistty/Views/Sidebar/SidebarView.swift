import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore

    var body: some View {
        List {
            ForEach(store.sessions) { session in
                SessionRowView(session: session, store: store)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
    }
}

struct SessionRowView: View {
    @Bindable var session: MisttySession
    @Bindable var store: SessionStore
    @State private var isExpanded = true

    var isActive: Bool { store.activeSession?.id == session.id }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(session.tabs) { tab in
                HStack {
                    Text(tab.title)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.activeSession = session
                    session.activeTab = tab
                }
            }
        } label: {
            Text(session.name)
                .fontWeight(isActive ? .semibold : .regular)
                .contentShape(Rectangle())
                .onTapGesture { store.activeSession = session }
        }
    }
}
