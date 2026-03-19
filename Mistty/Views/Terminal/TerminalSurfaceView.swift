import AppKit
import GhosttyKit

final class TerminalSurfaceView: NSView {
  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
  var onSelect: (() -> Void)?

  /// Back-reference to the owning pane (set by MisttyPane).
  weak var pane: MisttyPane?

  /// Stores the working directory path string to keep it alive for the C pointer.
  private var workingDirectoryPath: String?

  /// Stores the command string to keep it alive for the C pointer.
  private var commandString: String?

  /// Stores the initial input string to keep it alive for the C pointer.
  private var initialInputString: String?

  init(
    frame: NSRect, workingDirectory: URL? = nil, command: String? = nil, initialInput: String? = nil
  ) {
    super.init(frame: frame)
    wantsLayer = true

    guard let app = GhosttyAppManager.shared.app else {
      print("[TerminalSurfaceView] No ghostty app available")
      return
    }

    var cfg = ghostty_surface_config_new()
    cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
    cfg.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      )
    )
    cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
    cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    // Set working directory for the shell
    if let dir = workingDirectory {
      workingDirectoryPath = dir.path
    }

    // Store command string
    self.commandString = command

    // For popups that should close on exit, send the command as initial_input
    // instead of cfg.command. ghostty forces wait-after-command=true when
    // cfg.command is set, which shows "press any key to close". Using
    // initial_input runs the command in the shell naturally.
    if let input = initialInput {
      self.initialInputString = "exec \(input)\n"
    }

    // Both C pointers from withCString are only valid inside the closure,
    // so we nest them to ensure they're alive when ghostty_surface_new is called.
    func createSurface(_ cfg: inout ghostty_surface_config_s) {
      if let path = workingDirectoryPath {
        path.withCString { dirPtr in
          cfg.working_directory = dirPtr
          if let cmd = commandString {
            cmd.withCString { cmdPtr in
              cfg.command = cmdPtr
              if let input = initialInputString {
                input.withCString { inputPtr in
                  cfg.initial_input = inputPtr
                  surface = ghostty_surface_new(app, &cfg)
                }
              } else {
                surface = ghostty_surface_new(app, &cfg)
              }
            }
          } else if let input = initialInputString {
            input.withCString { inputPtr in
              cfg.initial_input = inputPtr
              surface = ghostty_surface_new(app, &cfg)
            }
          } else {
            surface = ghostty_surface_new(app, &cfg)
          }
        }
      } else if let cmd = commandString {
        cmd.withCString { cmdPtr in
          cfg.command = cmdPtr
          if let input = initialInputString {
            input.withCString { inputPtr in
              cfg.initial_input = inputPtr
              surface = ghostty_surface_new(app, &cfg)
            }
          } else {
            surface = ghostty_surface_new(app, &cfg)
          }
        }
      } else if let input = initialInputString {
        input.withCString { inputPtr in
          cfg.initial_input = inputPtr
          surface = ghostty_surface_new(app, &cfg)
        }
      } else {
        surface = ghostty_surface_new(app, &cfg)
      }
    }

    createSurface(&cfg)

    if surface == nil {
      print("[TerminalSurfaceView] ghostty_surface_new failed")
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Not implemented") }

  deinit {
    if let surface { ghostty_surface_free(surface) }
  }

  // MARK: - Responder

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    if let surface { ghostty_surface_set_focus(surface, true) }
    return true
  }

  override func resignFirstResponder() -> Bool {
    if let surface { ghostty_surface_set_focus(surface, false) }
    return true
  }

  // MARK: - Grid Metrics

  struct GridMetrics {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
  }

  /// Returns cell dimensions in points and the grid's top-left offset within the view.
  func gridMetrics() -> GridMetrics? {
    guard let surface else { return nil }
    let size = ghostty_surface_size(surface)
    guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    let cellW = CGFloat(size.cell_width_px) / scale
    let cellH = CGFloat(size.cell_height_px) / scale
    // Ghostty positions the grid at (window-padding-x, window-padding-y) from top-left.
    // Default window-padding is 2pt on all sides. Blank space goes to bottom/right.
    let padding: CGFloat = 2.0
    return GridMetrics(cellWidth: cellW, cellHeight: cellH, offsetX: padding, offsetY: padding)
  }

  /// Returns the terminal cursor position as (row, col) in grid coordinates.
  func cursorPosition() -> (row: Int, col: Int)? {
    guard let surface else { return nil }
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0
    var h: Double = 0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    guard let metrics = gridMetrics() else { return nil }
    // ime_point returns point coordinates (not pixels).
    // y points to the bottom of the cursor cell, so subtract one cell height.
    let col = Int((CGFloat(x) - metrics.offsetX) / metrics.cellWidth)
    let row = Int((CGFloat(y) - metrics.offsetY - metrics.cellHeight) / metrics.cellHeight)
    let size = ghostty_surface_size(surface)
    return (row: max(0, min(row, Int(size.rows) - 1)), col: max(0, min(col, Int(size.columns) - 1)))
  }

  // MARK: - Layout

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    guard let surface, let window else { return }
    let scale = window.backingScaleFactor
    let w = UInt32(newSize.width * scale)
    let h = UInt32(newSize.height * scale)
    ghostty_surface_set_size(surface, w, h)
    ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    setFrameSize(frame.size)
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard Input

  /// Accumulates text from interpretKeyEvents → insertText
  private var keyTextAccumulator: [String] = []

  override func keyDown(with event: NSEvent) {
    guard let surface else { return }

    let action: ghostty_input_action_e =
      event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    // Use interpretKeyEvents to get OS-resolved text (handles keyboard layouts, dead keys, IME)
    keyTextAccumulator = []
    interpretKeyEvents([event])

    if keyTextAccumulator.isEmpty {
      // No text produced (e.g. Escape, arrows, function keys) — send key event only
      let keyEvent = buildKeyEvent(action: action, event: event)
      _ = ghostty_surface_key(surface, keyEvent)
    } else {
      // Send key event with accumulated text
      for text in keyTextAccumulator {
        var keyEvent = buildKeyEvent(action: action, event: event)
        text.withCString { ptr in
          keyEvent.text = ptr
          _ = ghostty_surface_key(surface, keyEvent)
        }
      }
    }
  }

  override func keyUp(with event: NSEvent) {
    guard let surface else { return }
    let keyEvent = buildKeyEvent(action: GHOSTTY_ACTION_RELEASE, event: event)
    _ = ghostty_surface_key(surface, keyEvent)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface else { return }

    // Determine if this modifier key is being pressed or released
    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    let pressed = ghosttyMods(event.modifierFlags).rawValue & mod != 0
    let action: ghostty_input_action_e = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    let keyEvent = buildKeyEvent(action: action, event: event)
    _ = ghostty_surface_key(surface, keyEvent)
  }

  private func buildKeyEvent(action: ghostty_input_action_e, event: NSEvent) -> ghostty_input_key_s
  {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = ghosttyMods(event.modifierFlags)
    key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
    key.text = nil
    key.composing = false

    // Unshifted codepoint
    key.unshifted_codepoint = 0
    if event.type == .keyDown || event.type == .keyUp {
      if let chars = event.characters(byApplyingModifiers: []),
        let codepoint = chars.unicodeScalars.first
      {
        key.unshifted_codepoint = codepoint.value
      }
    }

    return key
  }

  // MARK: - Mouse Input

  override func mouseDown(with event: NSEvent) {
    onSelect?()
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, Double(point.x), Double(frame.height - point.y), ghosttyMods(event.modifierFlags))
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
  }

  override func mouseUp(with event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, Double(point.x), Double(frame.height - point.y), ghosttyMods(event.modifierFlags))
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
  }

  override func mouseMoved(with event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, Double(point.x), Double(frame.height - point.y), ghosttyMods(event.modifierFlags))
  }

  override func mouseDragged(with event: NSEvent) {
    mouseMoved(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
  }

  private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
  }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    // Accumulate text for keyDown to pass to ghostty_surface_key.
    // Do NOT call ghostty_surface_text here — that would double-send.
    let str: String
    if let s = string as? String {
      str = s
    } else if let attrStr = string as? NSAttributedString {
      str = attrStr.string
    } else {
      str = String(describing: string)
    }
    keyTextAccumulator.append(str)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    // IME composition stub
  }

  func unmarkText() {}

  func selectedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  func markedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool { false }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else { return .zero }
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0
    var h: Double = 0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    let viewPoint = NSPoint(x: x, y: frame.height - y)
    guard let window else { return NSRect(origin: viewPoint, size: NSSize(width: w, height: h)) }
    let windowPoint = convert(viewPoint, to: nil)
    let screenPoint = window.convertPoint(toScreen: windowPoint)
    return NSRect(origin: screenPoint, size: NSSize(width: w, height: h))
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }
}
