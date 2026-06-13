import GhosttyKit

/// The surface operations copy-mode orchestration needs, abstracted so
/// `CopyModeController` can be driven by a fake in tests instead of a live
/// libghostty surface. `TerminalSurfaceView` already implements every member;
/// the conformance below is empty.
@MainActor
protocol TerminalContentReading: AnyObject {
  /// Read one full row of text (viewport row by default; screen row via tag).
  func readRow(_ row: Int, pointTag: ghostty_point_tag_e) -> String?

  /// Read an arbitrary text range.
  func readText(
    startRow: Int, startCol: Int, endRow: Int, endCol: Int,
    rectangle: Bool, pointTag: ghostty_point_tag_e
  ) -> String?

  /// The live viewport grid size, or nil if the surface isn't ready.
  func viewportGridSize() -> (rows: Int, cols: Int)?

  /// The terminal cursor's viewport position, or nil if unavailable.
  func cursorPosition() -> (row: Int, col: Int)?

  /// Scrollbar geometry. The orchestration writes `offset` synchronously to
  /// front-run ghostty's async scrollbar callback during search/scroll.
  var scrollbarState: ScrollbarState { get set }

  /// Run a ghostty keybinding action by name.
  func runBindingAction(_ action: String)

  /// Freeze the viewport at the current top row.
  func pinViewport()
}

extension TerminalSurfaceView: TerminalContentReading {}
