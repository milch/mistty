import AppKit
import SwiftUI

struct PaneLayoutView: View {
  let node: PaneLayoutNode
  let activePane: MisttyPane?
  var isWindowModeActive: Bool = false
  var copyModeState: CopyModeState?
  var copyModePaneID: Int?
  var windowModeState: MisttyTab.WindowModeState = .inactive
  var joinPickTabNames: [String] = []
  var paneCount: Int = 1
  var borderColor: Color = Color(NSColor.separatorColor)
  var borderWidth: CGFloat = 1
  var onClosePane: ((MisttyPane) -> Void)?
  var onSelectPane: ((MisttyPane) -> Void)?
  /// Called as the user drags a split divider. `delta` is a ratio-space
  /// increment in [-1, 1] against the split's container size. The receiver
  /// is expected to mutate the underlying layout via
  /// `PaneLayout.resizeSplit(between:and:delta:)`.
  var onResizeBetween: ((MisttyPane, MisttyPane, CGFloat) -> Void)?

  var body: some View {
    switch node {
    case .empty:
      Color(nsColor: .windowBackgroundColor)
    case .leaf(let pane):
      PaneView(
        pane: pane,
        isActive: activePane?.id == pane.id,
        isWindowModeActive: isWindowModeActive,
        copyModeState: (pane.id == copyModePaneID) ? copyModeState : nil,
        windowModeState: windowModeState,
        joinPickTabNames: joinPickTabNames,
        paneCount: paneCount,
        onClose: { onClosePane?(pane) },
        onSelect: { onSelectPane?(pane) }
      )
    case .split(let direction, let a, let b, let ratio):
      // ZStack with absolute positioning so the divider can be a 12pt-wide
      // hit target sitting *on top of* the panes' boundary — without that,
      // an HStack/VStack layout forces a tradeoff between either a visible
      // gap (divider takes layout space) or a 1pt hit area (`.overlay`
      // extends visually but `.onHover` follows NSTrackingArea on the
      // parent's 1pt frame, so the cursor only flips on the visible line).
      // Mirrors ghostty's own SplitView approach.
      GeometryReader { geo in
        let total: CGFloat = direction == .horizontal ? geo.size.width : geo.size.height
        let aSize = total * ratio
        let bSize = total - aSize
        ZStack(alignment: .topLeading) {
          if direction == .horizontal {
            child(a)
              .frame(width: aSize, height: geo.size.height)
            child(b)
              .frame(width: bSize, height: geo.size.height)
              .offset(x: aSize)
            divider(direction: .horizontal, a: a, b: b, containerSize: geo.size.width)
              .position(x: aSize, y: geo.size.height / 2)
          } else {
            child(a)
              .frame(width: geo.size.width, height: aSize)
            child(b)
              .frame(width: geo.size.width, height: bSize)
              .offset(y: aSize)
            divider(direction: .vertical, a: a, b: b, containerSize: geo.size.height)
              .position(x: geo.size.width / 2, y: aSize)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func divider(
    direction: SplitDirection,
    a: PaneLayoutNode,
    b: PaneLayoutNode,
    containerSize: CGFloat
  ) -> some View {
    if let aRep = Self.firstLeaf(a), let bRep = Self.firstLeaf(b),
      let onResizeBetween
    {
      SplitDivider(
        direction: direction,
        borderColor: borderColor,
        borderWidth: borderWidth,
        containerSize: containerSize,
        aRep: aRep,
        bRep: bRep,
        onResize: onResizeBetween
      )
    } else {
      borderColor
        .frame(
          width: direction == .horizontal ? borderWidth : nil,
          height: direction == .vertical ? borderWidth : nil
        )
    }
  }

  @ViewBuilder
  private func child(_ node: PaneLayoutNode) -> some View {
    PaneLayoutView(
      node: node, activePane: activePane, isWindowModeActive: isWindowModeActive,
      copyModeState: copyModeState, copyModePaneID: copyModePaneID,
      windowModeState: windowModeState, joinPickTabNames: joinPickTabNames,
      paneCount: paneCount,
      borderColor: borderColor, borderWidth: borderWidth,
      onClosePane: onClosePane, onSelectPane: onSelectPane,
      onResizeBetween: onResizeBetween
    )
  }

  private static func firstLeaf(_ node: PaneLayoutNode) -> MisttyPane? {
    switch node {
    case .leaf(let p): return p
    case .empty: return nil
    case .split(_, let a, _, _): return firstLeaf(a)
    }
  }
}

/// 12pt-wide draggable strip with a thin visible border centered inside it.
/// The whole strip is the gesture/hover target so NSTrackingArea covers the
/// full hit zone (a parent-overlay arrangement leaves the cursor flipping
/// only on the visible 1pt line, even when the gesture itself extends).
/// `.position()`-anchored by the parent so it sits over the panes' boundary
/// rather than pushing them apart.
private struct SplitDivider: View {
  let direction: SplitDirection
  let borderColor: Color
  let borderWidth: CGFloat
  let containerSize: CGFloat
  let aRep: MisttyPane
  let bRep: MisttyPane
  let onResize: (MisttyPane, MisttyPane, CGFloat) -> Void

  @State private var lastTranslation: CGFloat = 0

  private static let hitThickness: CGFloat = 12

  var body: some View {
    // Color.clear is the actual hit target — it fills the full hitThickness
    // frame so SwiftUI/AppKit allocates an NSTrackingArea covering the
    // entire grabbable zone. The earlier ZStack wrapped a 1pt borderColor
    // and used `.frame` + `.contentShape` to "extend" the hit area, but
    // .onHover follows the underlying NSView's tracking rect (sized to
    // real content), so the cursor only flipped over the 1pt visible
    // line. Filling the frame with Color.clear gives onHover a real
    // 12pt target. The visible border is an overlay on top.
    Color.clear
      .frame(
        width: direction == .horizontal ? Self.hitThickness : nil,
        height: direction == .vertical ? Self.hitThickness : nil
      )
      .overlay {
        borderColor
          .frame(
            width: direction == .horizontal ? borderWidth : nil,
            height: direction == .vertical ? borderWidth : nil
          )
      }
      .contentShape(Rectangle())
      // .pointerStyle (macOS 15+) integrates with AppKit's cursor-rect
      // z-ordering so the resize cursor wins over the TerminalSurfaceView
      // sitting underneath. NSCursor.push() from .onHover races against
      // ghostty's own cursor pushes on mouseMoved (most recent push wins),
      // which is why hover-cursor was unreliable. Fall back to NSCursor on
      // macOS 14 where .pointerStyle isn't available.
      .modifier(SplitCursorModifier(direction: direction))
      .gesture(
      // .global is critical: the divider view itself moves as the ratio
      // updates, so a .local gesture sees the cursor "snap back" toward
      // its start each frame and translation oscillates around zero —
      // visually the divider lags and jumps. .global reports translation
      // in screen coords, invariant to the divider's own movement.
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { value in
          let axis =
            direction == .horizontal
            ? value.translation.width : value.translation.height
          let incremental = axis - lastTranslation
          lastTranslation = axis
          guard containerSize > 0, incremental != 0 else { return }
          onResize(aRep, bRep, incremental / containerSize)
        }
        .onEnded { _ in
          lastTranslation = 0
        }
    )
  }
}

private struct SplitCursorModifier: ViewModifier {
  let direction: SplitDirection

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(
        direction == .horizontal
          ? .frameResize(position: .trailing)
          : .frameResize(position: .top)
      )
    } else {
      content.onHover { hovering in
        if hovering {
          (direction == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
            .push()
        } else {
          NSCursor.pop()
        }
      }
    }
  }
}
