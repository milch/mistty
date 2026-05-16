import SwiftUI

struct TabBarView: View {
  @Bindable var session: MisttySession
  var leadingInset: CGFloat = 0

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(session.tabs) { tab in
            TabBarItem(
              tab: tab,
              isActive: session.activeTab?.id == tab.id,
              // `[weak tab]` — same retention pattern as the pane
              // closures fixed in e44e17f. SwiftUI's view tree can
              // outlive `session.tabs.removeAll`, so a strong capture
              // here pins the tab (and through `tab.layout`, its
              // pane + libghostty surface).
              onSelect: { [weak tab] in if let tab { session.activeTab = tab } },
              onClose: { [weak tab] in if let tab { session.closeTab(tab) } }
            )
          }
        }
        .padding(.horizontal, 6)
      }
      .padding(.leading, leadingInset)

      Button(action: {
        NotificationCenter.default.post(name: .misttyNewTab, object: nil)
      }) {
        Image(systemName: "plus")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .padding(.trailing, 4)
    }
    .frame(height: 28)
    .background(.bar)
  }
}

struct TabBarItem: View {
  @Bindable var tab: MisttyTab
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var isEditing = false
  @State private var editText = ""
  @FocusState private var editFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      if tab.zoomedPane != nil {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(isActive ? .secondary : .tertiary)
          .help("Zoomed pane")
      }

      if isEditing {
        TextField(
          "Tab name", text: $editText,
          onCommit: {
            tab.customTitle = editText.isEmpty ? nil : editText
            isEditing = false
          }
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .focused($editFocused)
        .frame(maxWidth: 120)
        .onAppear { editFocused = true }
      } else {
        Text(tab.displayTitle)
          .font(.system(size: 11))
          .foregroundStyle(isActive ? .primary : .secondary)
          .lineLimit(1)
          .onTapGesture(count: 2) {
            editText = tab.displayTitle
            isEditing = true
          }
      }

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 9))
      }
      .buttonStyle(.plain)
      .opacity(isActive ? 1 : 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(tabBackground)
    .cornerRadius(5)
    .onTapGesture { onSelect() }
    .onReceive(NotificationCenter.default.publisher(for: .misttyRenameTab)) { _ in
      if isActive {
        editText = tab.displayTitle
        isEditing = true
      }
    }
  }

  private var tabBackground: Color {
    if isActive { return Color.primary.opacity(0.08) }
    if tab.hasBell { return Color.orange.opacity(0.22) }
    return Color.clear
  }
}
