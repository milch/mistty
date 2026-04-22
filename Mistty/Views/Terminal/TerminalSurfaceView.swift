import AppKit
import GhosttyKit

final class TerminalSurfaceView: NSView {
  /// When true, skip libghostty surface creation entirely. Snapshot tests
  /// flip this so the embedded terminal doesn't spawn a shell whose
  /// "Last login: <date>" output would make the snapshot non-deterministic.
  nonisolated(unsafe) static var skipSurfaceCreation = false

  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
  var onSelect: (() -> Void)?
  var scrollbarState = ScrollbarState()

  /// Whether this surface owns its tab's focus. Gates the first-responder
  /// grab in `viewDidMoveToWindow` so that re-mounting a multi-pane session
  /// doesn't hand keyboard input to whichever pane happens to be hosted last.
  /// Plumbed in from SwiftUI via `TerminalSurfaceRepresentable`.
  var isActive: Bool = false

  /// Back-reference to the owning pane (set by MisttyPane).
  weak var pane: MisttyPane?

  /// Stores the working directory path string to keep it alive for the C pointer.
  private var workingDirectoryPath: String?

  /// Stores the command string to keep it alive for the C pointer.
  private var commandString: String?

  /// Stores the initial input string to keep it alive for the C pointer.
  private var initialInputString: String?

  /// Mistty's configured leading content padding, captured at init so
  /// `gridMetrics()` doesn't do disk IO on every frame. Config changes
  /// currently require a restart, so caching is safe.
  private let configuredPaddingX: CGFloat
  private let configuredPaddingY: CGFloat
  private let configuredPaddingBalance: Bool

  init(
    frame: NSRect,
    workingDirectory: URL? = nil,
    command: String? = nil,
    initialInput: String? = nil,
    waitAfterCommand: Bool = true
  ) {
    // Use the shared launch-time parse so init doesn't re-read config.toml
    // per pane and stays consistent with the lines sent to libghostty.
    let ui = MisttyConfig.loadedAtLaunch.config.ui
    self.configuredPaddingX = CGFloat(ui.contentPaddingX?.first ?? Int(Self.ghosttyDefaultPadding))
    self.configuredPaddingY = CGFloat(ui.contentPaddingY?.first ?? Int(Self.ghosttyDefaultPadding))
    self.configuredPaddingBalance = ui.contentPaddingBalance ?? false

    super.init(frame: frame)
    wantsLayer = true

    if Self.skipSurfaceCreation {
      return
    }

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
    // Requires the Mistty patch that removes ghostty's unconditional
    // `wait-after-command = true` when `cfg.command` is set. Without the
    // patch this flag is effectively ignored (always true for command panes).
    cfg.wait_after_command = waitAfterCommand

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

  /// Ghostty's default padding when `window-padding-x/y` isn't set.
  private static let ghosttyDefaultPadding: CGFloat = 2.0

  /// Leading padding inside the surface, in points — i.e. the offset of the
  /// grid's top-left from `(0, 0)`. Matches what ghostty does based on
  /// Mistty's configured `window-padding-x/y` values, plus half the leftover
  /// pixels when `window-padding-balance` is on.
  private func leadingPadding(surfaceSize: ghostty_surface_size_s, scale: CGFloat)
    -> (x: CGFloat, y: CGFloat)
  {
    if configuredPaddingBalance {
      let gridWidth = CGFloat(surfaceSize.cell_width_px) * CGFloat(surfaceSize.columns) / scale
      let gridHeight = CGFloat(surfaceSize.cell_height_px) * CGFloat(surfaceSize.rows) / scale
      return (
        max(0, bounds.width - gridWidth) / 2,
        max(0, bounds.height - gridHeight) / 2
      )
    }
    return (configuredPaddingX, configuredPaddingY)
  }

  /// Returns cell dimensions in points and the grid's top-left offset within the view.
  func gridMetrics() -> GridMetrics? {
    guard let surface else { return nil }
    let size = ghostty_surface_size(surface)
    guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    let cellW = CGFloat(size.cell_width_px) / scale
    let cellH = CGFloat(size.cell_height_px) / scale
    let (padX, padY) = leadingPadding(surfaceSize: size, scale: scale)
    return GridMetrics(cellWidth: cellW, cellHeight: cellH, offsetX: padX, offsetY: padY)
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
    if isActive {
      window?.makeFirstResponder(self)
    }
  }

  /// Propagate system light/dark switches to libghostty. The app-level
  /// `ghostty_app_set_color_scheme` only bumps the app's conditional state —
  /// existing surfaces keep their own `config_conditional_state`, so without
  /// this call dual themes like `theme = light:X,dark:Y` stay stuck on
  /// whichever variant was active when the surface was created.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard let surface else { return }
    let scheme: ghostty_color_scheme_e =
      effectiveAppearance.name.rawValue.lowercased().contains("dark")
        ? GHOSTTY_COLOR_SCHEME_DARK
        : GHOSTTY_COLOR_SCHEME_LIGHT
    ghostty_surface_set_color_scheme(surface, scheme)
  }

  /// Push new backing scale to libghostty when the view's display changes
  /// (plug/unplug a monitor, move the window to a different screen). Without
  /// this, the surface keeps the scale it was created with — so a Retina-born
  /// surface that later lands on a @1x display renders at half size, and
  /// vice versa. `setFrameSize` already handles size-driven updates, but
  /// screen moves with identical point dimensions don't resize.
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface, let window else { return }
    let scale = window.backingScaleFactor
    let w = UInt32(bounds.width * scale)
    let h = UInt32(bounds.height * scale)
    ghostty_surface_set_size(surface, w, h)
    ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    DebugLog.shared.log(
      "scale",
      "viewDidChangeBackingProperties: scale=\(scale) size=\(w)x\(h)px bounds=\(bounds.size)"
    )
  }

  // MARK: - Keyboard Input

  /// Text accumulated from `interpretKeyEvents → insertText` during a keyDown.
  /// `nil` when we're outside a keyDown — NSTextInputClient callbacks use this
  /// to decide whether to defer state sync (in-flight keyDown) or apply it
  /// immediately (input method panel, script events, etc.).
  private var keyTextAccumulator: [String]?

  /// IME preedit ("marked text") — populated by `setMarkedText`, pushed to
  /// libghostty via `ghostty_surface_preedit` so the terminal renders the
  /// in-progress composition inline under the cursor.
  private var markedText = NSMutableAttributedString()

  /// Intercepts key-equivalents AppKit would normally route past `keyDown`.
  /// Most Cmd-keys are handled by Mistty's menu/SwiftUI shortcuts — return
  /// false to let the responder chain take them. We only synthesise keyDown
  /// for events AppKit would otherwise swallow:
  ///   - `C-Return`: macOS binds Control+Return as a "context menu" equivalent
  ///     on some views, so reach past that to the terminal.
  ///   - `C-/`: AppKit emits its own NSBeep *before* keyDown fires; remap
  ///     to `C-_` (terminals use this for vim/readline undo).
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    guard window?.firstResponder === self else { return false }

    let equivalent: String
    switch event.charactersIgnoringModifiers {
    case "\r":
      if !event.modifierFlags.contains(.control) { return false }
      equivalent = "\r"
    case "/":
      // Require plain Ctrl (no shift/cmd/opt) — otherwise let chord through.
      if !event.modifierFlags.contains(.control)
        || !event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
      {
        return false
      }
      equivalent = "_"
    default:
      return false
    }

    guard
      let final = NSEvent.keyEvent(
        with: .keyDown,
        location: event.locationInWindow,
        modifierFlags: event.modifierFlags,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: equivalent,
        charactersIgnoringModifiers: equivalent,
        isARepeat: event.isARepeat,
        keyCode: event.keyCode)
    else { return false }

    keyDown(with: final)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard surface != nil else { return }

    let action: ghostty_input_action_e =
      event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    // Snapshot composition state before interpretKeyEvents so we can tell
    // whether this keystroke just cancelled an in-progress compose. If it did,
    // the compose was the consumer (e.g. Japanese backspace) and the shell
    // must NOT receive the key.
    let markedTextBefore = markedText.length > 0

    // Translate mods for text interpretation (e.g. macos-option-as-alt strips
    // option before AppKit resolves characters, so Option+1 → "1" instead of
    // "¡" — letting us pass the real event (with Option still set) to ghostty
    // for ESC-prefix encoding). The original event still drives key encoding.
    let translationEvent = translationEvent(for: event)

    keyTextAccumulator = []
    interpretKeyEvents([translationEvent])
    let accumulated = keyTextAccumulator ?? []
    keyTextAccumulator = nil

    // Sync preedit to libghostty before the key event so the terminal grid is
    // consistent if an action is bound to the event.
    syncPreedit(clearIfNeeded: markedTextBefore)

    if !accumulated.isEmpty {
      // Composed text or plain insertion — send each chunk with composing=false.
      for text in accumulated {
        sendKeyEvent(
          action: action, event: event, translationMods: translationEvent.modifierFlags,
          text: text, composing: false)
      }
    } else {
      // No text produced. `composing` is true when we're mid-composition OR
      // when this keystroke just cleared one — the latter prevents the shell
      // from seeing the canceling key.
      let composing = markedText.length > 0 || markedTextBefore
      sendKeyEvent(
        action: action, event: event, translationMods: translationEvent.modifierFlags,
        text: nil, composing: composing)
    }
  }

  override func keyUp(with event: NSEvent) {
    sendKeyEvent(
      action: GHOSTTY_ACTION_RELEASE, event: event, translationMods: nil, text: nil,
      composing: false)
  }

  private func sendKeyEvent(
    action: ghostty_input_action_e, event: NSEvent,
    translationMods: NSEvent.ModifierFlags?, text: String?, composing: Bool
  ) {
    guard let surface else { return }
    var key = buildKeyEvent(action: action, event: event, translationMods: translationMods)
    key.composing = composing
    // Only forward printable text — control chars and PUA (function keys)
    // are encoded by libghostty itself.
    if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
      text.withCString { ptr in
        key.text = ptr
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      _ = ghostty_surface_key(surface, key)
    }
  }

  /// Returns an event to feed `interpretKeyEvents` for AppKit text translation.
  /// Strips modifiers that the user's config wants ghostty to handle (e.g.
  /// option-as-alt) so AppKit resolves the raw key. When no translation is
  /// needed the original event is returned — important because AppKit's IME
  /// plumbing (Korean, dead keys) relies on event object identity.
  private func translationEvent(for event: NSEvent) -> NSEvent {
    guard let surface else { return event }
    let translated = ghostty_surface_key_translation_mods(
      surface, ghosttyMods(event.modifierFlags))
    let translatedFlags = nsFlags(fromGhosttyMods: translated)

    // Preserve non-modifier bits (device side flags, dead-key state markers)
    // and rewrite only the four standard modifiers.
    var newFlags = event.modifierFlags
    for flag: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
      if translatedFlags.contains(flag) {
        newFlags.insert(flag)
      } else {
        newFlags.remove(flag)
      }
    }

    if newFlags == event.modifierFlags { return event }

    return NSEvent.keyEvent(
      with: event.type,
      location: event.locationInWindow,
      modifierFlags: newFlags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: event.characters(byApplyingModifiers: newFlags) ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat,
      keyCode: event.keyCode
    ) ?? event
  }

  private func nsFlags(fromGhosttyMods mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags(rawValue: 0)
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  private func syncPreedit(clearIfNeeded: Bool) {
    guard let surface else { return }
    if markedText.length > 0 {
      let str = markedText.string
      let bytes = str.utf8CString.count
      guard bytes > 1 else { return }
      str.withCString { ptr in
        ghostty_surface_preedit(surface, ptr, UInt(bytes - 1))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface else { return }

    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    // Don't send modifier events during IME composition — a stray shift while
    // composing Korean/Japanese would otherwise leak mid-composition state.
    if markedText.length > 0 { return }

    // If the modifier bit is set, we still need to figure out if THIS event
    // is a press (the specific side that fired) or a release (user let go of
    // this side while the other side is still held). Device masks tell us
    // which physical key produced the event.
    var action = GHOSTTY_ACTION_RELEASE
    if ghosttyMods(event.modifierFlags).rawValue & mod != 0 {
      let raw = event.modifierFlags.rawValue
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
      default: sidePressed = true  // left-side and caps: no separate mask
      }
      if sidePressed { action = GHOSTTY_ACTION_PRESS }
    }

    let keyEvent = buildKeyEvent(action: action, event: event)
    _ = ghostty_surface_key(surface, keyEvent)
  }

  private func buildKeyEvent(
    action: ghostty_input_action_e, event: NSEvent,
    translationMods: NSEvent.ModifierFlags? = nil
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = ghosttyMods(event.modifierFlags)
    // Heuristic: control and command never contribute to text translation;
    // everything else does. When option-as-alt is on, libghostty strips option
    // from `translationMods` before AppKit resolves text, so option must NOT
    // appear in consumed_mods (otherwise ghostty treats option as already
    // "consumed" and skips the ESC-prefix encoding vim expects).
    // Without this, kitty keyboard protocol also re-emits shift as a separate
    // modifier, which some TUIs (e.g. Claude Code) decode as lowercase.
    let modsForConsumption = translationMods ?? event.modifierFlags
    key.consumed_mods = ghosttyMods(modsForConsumption.subtracting([.control, .command]))
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
    let str: String
    if let s = string as? String {
      str = s
    } else if let attrStr = string as? NSAttributedString {
      str = attrStr.string
    } else {
      str = String(describing: string)
    }

    // insertText terminates any active composition.
    unmarkText()

    if keyTextAccumulator != nil {
      // In-flight keyDown: defer to sendKeyEvent so text rides the key event.
      keyTextAccumulator?.append(str)
      return
    }

    // Out-of-band text (e.g. from an IME panel) — send directly.
    guard let surface else { return }
    str.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(str.utf8.count))
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let v as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: v)
    case let v as String:
      markedText = NSMutableAttributedString(string: v)
    default:
      return
    }
    // Outside a keyDown, no one else will push preedit for us.
    if keyTextAccumulator == nil {
      syncPreedit(clearIfNeeded: true)
    }
  }

  func unmarkText() {
    if markedText.length > 0 {
      markedText.mutableString.setString("")
      syncPreedit(clearIfNeeded: true)
    }
  }

  func selectedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  func markedRange() -> NSRange {
    markedText.length > 0
      ? NSRange(location: 0, length: markedText.length)
      : NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool { markedText.length > 0 }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  /// Swallow unhandled key commands (escape, arrows, backspace, etc.) so the
  /// default NSResponder chain doesn't bubble them up to NSApp and trigger
  /// NSBeep. The key event itself still reaches ghostty via keyDown.
  override func doCommand(by selector: Selector) {
    // Intentionally empty.
  }

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
