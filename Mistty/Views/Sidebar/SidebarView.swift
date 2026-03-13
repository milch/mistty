import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore
    @Binding var width: CGFloat

    var body: some View {
        List {
            ForEach(store.sessions) { session in
                SessionRowView(session: session, store: store)
            }
        }
        .listStyle(.sidebar)
        .frame(width: width)
        .overlay(alignment: .trailing) {
            SidebarDragHandle(width: $width)
        }
    }
}

struct SidebarDragHandle: View {
    @Binding var width: CGFloat

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        width = max(140, min(400, value.location.x))
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
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
                    if tab.hasBell {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text(tab.displayTitle)
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
