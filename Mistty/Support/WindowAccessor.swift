import AppKit
import SwiftUI

/// Exposes the NSWindow that contains the SwiftUI view as soon as the view
/// is mounted. Use as a `.background(WindowAccessor { window in ... })` on
/// any SwiftUI view; the closure fires synchronously via
/// `viewDidMoveToWindow`, unlike `NSApplication.keyWindow` lookups in
/// `onAppear` which race against AppKit's key-window dance during launch and
/// state restoration. Nil is passed when the view detaches from its window.
struct WindowAccessor: NSViewRepresentable {
  let onBind: (NSWindow?) -> Void

  final class TrackingView: NSView {
    var onBind: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onBind?(window)
    }
  }

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.onBind = onBind
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onBind = onBind
  }
}
