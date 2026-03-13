import AppKit
import Foundation

@Observable
@MainActor
final class MisttyPane: Identifiable {
    let id = UUID()

    /// The persistent terminal surface view for this pane.
    /// Created lazily on first access so the ghostty surface lives
    /// for the lifetime of the pane, surviving SwiftUI view rebuilds.
    @ObservationIgnored
    lazy var surfaceView: TerminalSurfaceView = TerminalSurfaceView(frame: .zero)
}
