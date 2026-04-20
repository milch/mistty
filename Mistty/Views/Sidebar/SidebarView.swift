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
        let isActiveTab = isActive && session.activeTab?.id == tab.id
        HStack {
          Text(String(ProcessIcon.glyph(forProcessTitle: tab.activePane?.processTitle)))
            .font(.custom(ProcessIcon.fontName, size: 12))
            .foregroundStyle(isActiveTab ? Color.accentColor : .secondary)
            .frame(width: 14, alignment: .center)
          if tab.hasBell {
            Circle()
              .fill(Color.orange)
              .frame(width: 6, height: 6)
          }
          Text(tab.displayTitle)
            .font(.system(size: 12, weight: isActiveTab ? .semibold : .regular))
            .foregroundStyle(isActiveTab ? .primary : .secondary)
          if tab.zoomedPane != nil {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(isActiveTab ? .secondary : .tertiary)
              .help("Zoomed pane")
          }
          Spacer()
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background {
          RoundedRectangle(cornerRadius: 4)
            .fill(isActiveTab ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .overlay(alignment: .leading) {
          if isActiveTab {
            RoundedRectangle(cornerRadius: 1)
              .fill(Color.accentColor)
              .frame(width: 2)
              .padding(.vertical, 2)
          }
        }
        .animation(.easeInOut(duration: 0.15), value: isActiveTab)
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
    .animation(.easeInOut(duration: 0.15), value: isActive)
  }
}
