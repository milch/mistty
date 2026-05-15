import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Prefix on the dragged tab payload. Carried as a plain UTF-8 NSString
/// so the drop side can use the well-trodden NSItemProvider(object:)
/// path. A custom UTI would have been cleaner but macOS rewrites
/// dynamic UTIs through the pasteboard layer and the filter stopped
/// matching on the drop side; .draggable/.dropDestination had the
/// same problem one layer up. Drops missing this prefix are ignored
/// so arbitrary text dragged into the sidebar can't trigger a reorder.
private let sidebarTabDragPrefix = "mistty-sidebar-tab:"

/// Session-level shared state for the in-progress drag. Hoisting this
/// out of per-row `@State` makes the cleanup reliable: after
/// `performDrop` sets `hoveredTabID = nil`, any trailing `dropUpdated`
/// tick on the same row can be filtered out ("only mutate if we're
/// already the hovered row"). With per-row state, that trailing tick
/// would un-clear the indicator.
@MainActor
@Observable
final class SidebarTabDropTracker {
  var hoveredTabID: Int? = nil
  var position: SidebarTabRow.DropHover = .above
}

/// Session id of whichever tab is currently being dragged. `.onDrag`
/// stamps this; drop delegates read it synchronously to decide whether
/// the drag is from their own session. Cross-session moves aren't
/// supported yet, and the drop callbacks don't have access to the
/// payload synchronously (NSItemProvider loads are async), so this is
/// the only way to suppress the misleading insertion indicator before
/// the drop actually fires. Stale value between drags is harmless —
/// no drag is in progress to read it.
@MainActor private var sidebarDragSourceSessionID: Int? = nil

struct SidebarView: View {
  @Bindable var state: WindowState
  var windowsStore: WindowsStore
  @Binding var width: CGFloat
  var titleBarStyle: TitleBarStyle = .hiddenWithLights
  /// When true, the tab bar is currently visible and owns the
  /// `.misttyRenameTab` menu/shortcut editor. The sidebar then skips
  /// that notification to avoid two simultaneous inline editors.
  var tabBarVisible: Bool = false

  var body: some View {
    List {
      ForEach(state.sessions) { session in
        SessionRowView(session: session, state: state, tabBarVisible: tabBarVisible)
      }
      .onMove { source, destination in
        state.moveSessions(from: source, to: destination)
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
  @Bindable var state: WindowState
  var tabBarVisible: Bool = false
  @State private var isExpanded = true
  @State private var isEditing = false
  @State private var editText = ""
  @FocusState private var editFocused: Bool
  /// One tracker per session. Cross-session drops are rejected at the
  /// payload level, so two sessions never need to coordinate.
  @State private var dropTracker = SidebarTabDropTracker()

  var isActive: Bool { state.activeSession?.id == session.id }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(session.tabs) { tab in
        let isActiveTab = isActive && session.activeTab?.id == tab.id
        SidebarTabRow(
          session: session,
          state: state,
          tab: tab,
          isActiveTab: isActiveTab,
          tabBarVisible: tabBarVisible,
          dropTracker: dropTracker
        )
      }
    } label: {
      HStack(spacing: 6) {
        Text(String(ProcessIcon.glyph(forSession: session)))
          .font(.custom(ProcessIcon.fontName, size: 12))
          .foregroundStyle(.secondary)
          .frame(width: 14, alignment: .center)
        if isEditing {
          TextField(
            "Session name", text: $editText,
            onCommit: {
              session.customName = editText.isEmpty ? nil : editText
              finishEditing()
            }
          )
          .textFieldStyle(.plain)
          .fontWeight(isActive ? .semibold : .regular)
          .focused($editFocused)
          .onAppear { editFocused = true }
          .onExitCommand { finishEditing() }
          .onChange(of: editFocused) { _, focused in
            if !focused && isEditing {
              session.customName = editText.isEmpty ? nil : editText
              finishEditing()
            }
          }
        } else {
          Text(session.sidebarLabel)
            .fontWeight(isActive ? .semibold : .regular)
            .onTapGesture(count: 2) { beginEditing() }
        }
        Spacer()
      }
      .padding(.leading, 8)
      .padding(.vertical, 2)
      .overlay(alignment: .leading) {
        if isActive {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2)
            .padding(.vertical, 2)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        if isEditing { return }
        state.activeSession = session
      }
      .contextMenu {
        Button("Rename…") { beginEditing() }
        Button("Change Directory…") {
          state.activeSession = session
          NotificationCenter.default.post(
            name: .misttyReparentSession,
            object: nil,
            userInfo: ["sessionID": session.id]
          )
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .misttyRenameSession)) { _ in
        // Only the active session opens its inline editor on the shortcut.
        guard isActive else { return }
        beginEditing()
      }
    }
    .animation(.easeInOut(duration: 0.15), value: isActive)
  }

  private func beginEditing() {
    editText = session.customName ?? session.sidebarLabel
    isEditing = true
  }

  private func finishEditing() {
    isEditing = false
    editFocused = false
    // Hand first responder back to the terminal so subsequent keystrokes
    // don't stay trapped in the detached NSTextField — same reason the
    // tab-rename path does this.
    state.activeSession?.activeTab?.activePane?.focusKeyboardInput()
  }
}

struct SidebarTabRow: View {
  @Bindable var session: MisttySession
  @Bindable var state: WindowState
  @Bindable var tab: MisttyTab
  let isActiveTab: Bool
  let tabBarVisible: Bool
  let dropTracker: SidebarTabDropTracker
  @State private var isEditing = false
  @State private var editText = ""
  @FocusState private var editFocused: Bool
  @State private var rowHeight: CGFloat = 0

  enum DropHover { case above, below }

  private var dropHover: DropHover? {
    dropTracker.hoveredTabID == tab.id ? dropTracker.position : nil
  }

  var body: some View {
    HStack {
      Text(String(ProcessIcon.glyph(forProcessTitle: tab.activePane?.processTitle)))
        .font(.custom(ProcessIcon.fontName, size: 12))
        .foregroundStyle(isActiveTab ? Color.accentColor : (tab.hasBell ? Color.orange : .secondary))
        .frame(width: 14, alignment: .center)
      if isEditing {
        TextField(
          "Tab name", text: $editText,
          onCommit: {
            tab.customTitle = editText.isEmpty ? nil : editText
            finishEditing()
          }
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: isActiveTab ? .semibold : .regular))
        .focused($editFocused)
        .onAppear { editFocused = true }
        .onExitCommand { finishEditing() }
        .onChange(of: editFocused) { _, focused in
          if !focused && isEditing {
            tab.customTitle = editText.isEmpty ? nil : editText
            finishEditing()
          }
        }
      } else {
        Text(tab.displayTitle)
          .font(.system(size: 12, weight: isActiveTab ? .semibold : .regular))
          .foregroundStyle(isActiveTab ? .primary : .secondary)
          .onTapGesture(count: 2) { beginEditing() }
      }
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
        .fill(rowBackgroundColor)
    }
    .overlay(alignment: .leading) {
      if let stripeColor = leadingStripeColor {
        RoundedRectangle(cornerRadius: 1)
          .fill(stripeColor)
          .frame(width: 2)
          .padding(.vertical, 2)
      }
    }
    .overlay(alignment: .top) {
      if dropHover == .above {
        Rectangle().fill(Color.accentColor).frame(height: 2)
      }
    }
    .overlay(alignment: .bottom) {
      if dropHover == .below {
        Rectangle().fill(Color.accentColor).frame(height: 2)
      }
    }
    .background {
      // Capture the row's pixel height so the DropDelegate can decide
      // "above" vs "below" from the drop's local y coordinate. Stored
      // in @State so SwiftUI re-renders the overlay when geometry changes.
      GeometryReader { geo in
        Color.clear
          .onAppear { rowHeight = geo.size.height }
          .onChange(of: geo.size.height) { _, h in rowHeight = h }
      }
    }
    .animation(.easeInOut(duration: 0.15), value: isActiveTab)
    .contentShape(Rectangle())
    .onTapGesture {
      if isEditing { return }
      state.activeSession = session
      session.activeTab = tab
    }
    .onDrag {
      // Tab id alone is enough — MisttyTab IDs are globally unique. The
      // source session id is stamped into the shared var so drop
      // delegates on other sessions can suppress their indicator
      // synchronously; the payload itself only carries the tab id.
      let payload = "\(sidebarTabDragPrefix)\(tab.id)" as NSString
      let provider = NSItemProvider(object: payload)
      provider.suggestedName = tab.displayTitle
      sidebarDragSourceSessionID = session.id
      return provider
    }
    .onDrop(
      of: [UTType.utf8PlainText.identifier],
      delegate: SidebarTabDropDelegate(
        rowHeight: rowHeight,
        targetTabID: tab.id,
        ownerSessionID: session.id,
        tracker: dropTracker,
        onConfirmed: { droppedTabID, insertAfter in
          reorderDroppedTab(droppedTabID, insertAfter: insertAfter)
        }
      )
    )
    .onReceive(NotificationCenter.default.publisher(for: .misttyRenameTab)) { _ in
      // When the tab bar is visible its TabBarItem owns the rename
      // editor. The sidebar only picks up the shortcut when the tab
      // bar is hidden, so the menu/shortcut works everywhere.
      guard !tabBarVisible, isActiveTab else { return }
      beginEditing()
    }
  }

  /// Reorder a tab dropped onto this row. Same-session only — cross-session
  /// moves are deferred; the firstIndex lookup naturally rejects them by
  /// returning nil for tab ids that aren't in this session.
  ///
  /// `move(fromOffsets:toOffset:)` treats `toOffset` as the BOUNDARY in
  /// the original (pre-removal) array. "Insert above target" = boundary
  /// at the target's index. "Insert below target" = boundary at index+1
  /// — including the "drop on the last row's lower half ⇒ move to very
  /// end" case (toOffset = tabs.count).
  fileprivate func reorderDroppedTab(_ droppedTabID: Int, insertAfter: Bool) {
    guard let src = session.tabs.firstIndex(where: { $0.id == droppedTabID }),
          let dst = session.tabs.firstIndex(where: { $0.id == tab.id }),
          src != dst
    else { return }
    let toOffset = insertAfter ? dst + 1 : dst
    session.moveTabs(from: IndexSet(integer: src), to: toOffset)
  }

  private func beginEditing() {
    editText = tab.displayTitle
    isEditing = true
  }

  private func finishEditing() {
    isEditing = false
    editFocused = false
    // Hand first responder back to the terminal so subsequent
    // keystrokes don't stay trapped in the detached NSTextField.
    tab.activePane?.focusKeyboardInput()
  }

  private var rowBackgroundColor: Color {
    if isActiveTab { return Color.accentColor.opacity(0.18) }
    if tab.hasBell { return Color.orange.opacity(0.18) }
    return Color.clear
  }

  private var leadingStripeColor: Color? {
    if isActiveTab { return Color.accentColor }
    if tab.hasBell { return Color.orange }
    return nil
  }
}

/// Handles the drop side of sidebar tab reordering. Lives outside the
/// row so `DropInfo.location` (which is in the receiver's coordinate
/// space) can be compared against the row's captured pixel height and
/// the visual insertion bar can flip between `.above` and `.below`.
/// The closure-based `.onDrop(of:isTargeted:perform:)` doesn't expose
/// the drop location, hence the delegate form.
struct SidebarTabDropDelegate: DropDelegate {
  let rowHeight: CGFloat
  let targetTabID: Int
  let ownerSessionID: Int
  let tracker: SidebarTabDropTracker
  /// Called after the async NSItemProvider load resolves to a tab id.
  /// `insertAfter` is captured at performDrop time so a late hover
  /// update can't change which side of the row the drop lands on.
  let onConfirmed: (_ droppedTabID: Int, _ insertAfter: Bool) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    isSameSessionDrag && info.hasItemsConforming(to: [.utf8PlainText])
  }

  func dropEntered(info: DropInfo) {
    guard isSameSessionDrag else { return }
    tracker.hoveredTabID = targetTabID
    tracker.position = hover(for: info)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    // Cross-session: suppress the indicator AND signal "no drop here"
    // so macOS shows the forbidden-drop cursor. Cross-session moves
    // are intentionally a no-op today.
    guard isSameSessionDrag else {
      return DropProposal(operation: .forbidden)
    }
    // Only mutate when we're *already* the hovered row. A trailing
    // tick that fires after performDrop has cleared hoveredTabID
    // would otherwise un-clear the indicator. dropEntered is the
    // only path that legitimately claims this row.
    if tracker.hoveredTabID == targetTabID {
      let next = hover(for: info)
      if tracker.position != next { tracker.position = next }
    }
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if tracker.hoveredTabID == targetTabID {
      tracker.hoveredTabID = nil
    }
  }

  func performDrop(info: DropInfo) -> Bool {
    guard isSameSessionDrag else { return false }
    let insertAfter = hover(for: info) == .below
    tracker.hoveredTabID = nil
    let providers = info.itemProviders(for: [.utf8PlainText])
    loadSidebarTabIDPayload(from: providers) { droppedTabID in
      onConfirmed(droppedTabID, insertAfter)
    }
    return true
  }

  private var isSameSessionDrag: Bool {
    sidebarDragSourceSessionID == ownerSessionID
  }

  private func hover(for info: DropInfo) -> SidebarTabRow.DropHover {
    // Before GeometryReader has reported a height (first frame after
    // mount), default to .above so we never show a bottom bar on a
    // zero-height row. Once rowHeight stabilizes the next dropUpdated
    // corrects it.
    guard rowHeight > 0 else { return .above }
    return info.location.y < rowHeight / 2 ? .above : .below
  }
}

/// Free function so the drop delegate (which isn't a member of the row)
/// can call it. The NSItemProvider load is async; the inner hop back
/// to the main actor is the SwiftUI-safe place to mutate session state.
@MainActor
fileprivate func loadSidebarTabIDPayload(
  from providers: [NSItemProvider],
  then handler: @escaping @MainActor (Int) -> Void
) {
  guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) })
  else { return }
  _ = provider.loadObject(ofClass: NSString.self) { object, _ in
    // Materialize to Swift String inside the background callback so the
    // main-actor hop only ships a Sendable payload across the boundary.
    let raw: String? = (object as? NSString) as String?
    DispatchQueue.main.async {
      guard let str = raw,
            str.hasPrefix(sidebarTabDragPrefix),
            let id = Int(str.dropFirst(sidebarTabDragPrefix.count))
      else { return }
      handler(id)
    }
  }
}
