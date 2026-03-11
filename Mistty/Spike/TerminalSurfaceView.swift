import AppKit
import GhosttyKit

final class TerminalSurfaceView: NSView {
    nonisolated(unsafe) private var surface: ghostty_surface_t?

    override init(frame: NSRect) {
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

        surface = ghostty_surface_new(app, &cfg)
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

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        // Forward key up events if needed in the future
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes if needed in the future
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(frame.height - point.y), modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(frame.height - point.y), modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(frame.height - point.y), modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if event.modifierFlags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let str: String
        if let s = string as? String {
            str = s
        } else if let attrStr = string as? NSAttributedString {
            str = attrStr.string
        } else {
            str = String(describing: string)
        }
        str.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(str.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // IME composition - minimal stub for spike
    }

    func unmarkText() {}

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { false }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
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
