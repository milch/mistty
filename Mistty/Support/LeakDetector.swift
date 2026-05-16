import AppKit
import Foundation

/// Diagnostic for the popup/pane retention investigation. After
/// `closeTab` / `closePane`, the suspicion is that something outside
/// the model layer (most likely the SwiftUI view tree or its
/// `NSViewRepresentable` cache) is keeping `MisttyTab` and `MisttyPane`
/// strongly referenced — `deinit` never fires, so the libghostty
/// surface + threads + IOSurfaces stay alive.
///
/// We can't attach Xcode's memory graph debugger to a non-development
/// signed build, so this is a code-side stand-in:
///
///  1. Capture `weak` refs at close time
///  2. Wait long enough for SwiftUI to settle (view dismantle pass,
///     observation cleanup, autorelease pool drain — 2s is generous)
///  3. If the weak refs are still alive, log it as a confirmed leak
///  4. Walk every `NSWindow.contentView` subtree and report whether
///     the leaked pane's `TerminalSurfaceView` is still mounted —
///     that distinguishes "SwiftUI never dismantled the NSView"
///     (still in NSWindow tree) from "NSView dismantled but pane
///     held by something else" (not in NSWindow tree).
@MainActor
enum LeakDetector {
  /// Tunable in case 2s ever turns out to be too short for some
  /// teardown path (animations, etc.).
  static let delay: TimeInterval = 2.0

  static func scheduleCheck(tab: MisttyTab?, panes: [MisttyPane]) {
    let weakTab = WeakBox(tab)
    let weakPanes = panes.map { WeakBox($0) }
    let paneIDs = panes.map(\.id)
    let tabID = tab?.id

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      let stillAliveTab = weakTab.value != nil
      let stillAlivePanes = weakPanes.compactMap { $0.value?.id }

      if !stillAliveTab && stillAlivePanes.isEmpty {
        return  // healthy — nothing leaked
      }

      var summary = "LEAK CHECK \(Int(delay))s after close:"
      if let tabID, stillAliveTab {
        summary += " tab id=\(tabID) STILL ALIVE;"
      } else if let tabID {
        summary += " tab id=\(tabID) freed ✓;"
      }
      if !stillAlivePanes.isEmpty {
        summary += " panes STILL ALIVE: \(stillAlivePanes);"
      }
      let freedPanes = Set(paneIDs).subtracting(stillAlivePanes)
      if !freedPanes.isEmpty {
        summary += " panes freed ✓: \(freedPanes.sorted());"
      }

      // For each still-alive pane, check whether its TerminalSurfaceView
      // is hosted in any NSWindow's view tree. If yes → SwiftUI never
      // dismantled the NSViewRepresentable. If no → something else
      // (closure, observation, environment) holds the pane.
      for box in weakPanes {
        guard let pane = box.value else { continue }
        let surfaceView = pane.surfaceViewIfLoaded
        let mountedInWindow = surfaceView.flatMap { view -> NSWindow? in
          for window in NSApp.windows {
            if let content = window.contentView, viewContains(content, surfaceView: view) {
              return window
            }
          }
          return nil
        }
        if mountedInWindow != nil {
          summary +=
            " (paneID=\(pane.id): NSView still in NSWindow tree → SwiftUI"
            + " NSViewRepresentable not dismantled);"
        } else if surfaceView != nil {
          summary +=
            " (paneID=\(pane.id): NSView orphaned — not in any NSWindow →"
            + " held by non-AppKit ref);"
        } else {
          summary +=
            " (paneID=\(pane.id): no surfaceView loaded — pane held without"
            + " ever mounting);"
        }
      }

      DebugLog.shared.log("popup", summary)
    }
  }

  private static func viewContains(_ root: NSView, surfaceView: NSView) -> Bool {
    if root === surfaceView { return true }
    for sub in root.subviews where viewContains(sub, surfaceView: surfaceView) {
      return true
    }
    return false
  }

  /// `weak var` inside a generic helper — Swift won't let us put one
  /// directly into a `[WeakRef]` collection without a wrapper.
  private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
  }
}
