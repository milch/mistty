import SwiftUI

struct SidebarView: View {
  @Bindable var store: SessionStore
  @Binding var width: CGFloat
  var titleBarStyle: TitleBarStyle = .hiddenWithLights

  var body: some View {
    List {
      ForEach(store.sessions) { session in
        SessionRowView(session: session, store: store)
      }
    }
    .listStyle(.sidebar)
    .padding(.top, titleBarStyle.hasTrafficLights ? 28 : 0)
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
          Text(String(ProcessIcon.glyph(forProcessTitle: tab.activePane?.processTitle)))
            .font(.custom(ProcessIcon.fontName, size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 14, alignment: .center)
          if tab.hasBell {
            Circle()
              .fill(Color.orange)
              .frame(width: 6, height: 6)
          }
          Text(tab.displayTitle)
            .font(.system(size: 12))
          if tab.zoomedPane != nil {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
              .help("Zoomed pane")
          }
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
      HStack(spacing: 6) {
        Text(String(ProcessIcon.glyph(forSession: session)))
          .font(.custom(ProcessIcon.fontName, size: 12))
          .foregroundStyle(.secondary)
          .frame(width: 14, alignment: .center)
        Text(session.sidebarLabel)
          .fontWeight(isActive ? .semibold : .regular)
        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture { store.activeSession = session }
    }
  }
}
