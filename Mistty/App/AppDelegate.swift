import AppKit
import Foundation
import MisttyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `MisttyApp.init()` right after the adaptor materializes us.
  var windowsStore: WindowsStore!

  /// Strong ref so the observer outlives init. Set by `MisttyApp.init()`.
  var observer: StateRestorationObserver?

  private static let coderKey = "workspace"

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Multi-window terminal: closing all windows should keep the app running
    // (Cmd+N spawns a fresh empty window; Reopen Closed Window restores).
    return false
  }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    guard let windowsStore else {
      DebugLog.shared.log("restore", "willEncode: no store wired")
      return
    }
    let snapshot = windowsStore.takeSnapshot()
    do {
      let data = try JSONEncoder().encode(snapshot)
      coder.encode(data as NSData, forKey: Self.coderKey)
      // Stub for Task 4: count sessions from the first window.
      let totalSessions = snapshot.windows.flatMap(\.sessions).count
      DebugLog.shared.log(
        "restore",
        "encoded snapshot: \(totalSessions) sessions, \(data.count) bytes")
    } catch {
      DebugLog.shared.log("restore", "encode failed: \(error)")
    }
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    guard let windowsStore else {
      DebugLog.shared.log("restore", "didDecode: no store wired")
      return
    }
    guard let data = coder.decodeObject(of: NSData.self, forKey: Self.coderKey) as Data?
    else {
      DebugLog.shared.log("restore", "no workspace data in coder")
      return
    }
    do {
      let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
      if let bad = snapshot.unsupportedVersion {
        DebugLog.shared.log("restore", "unsupported version \(bad); starting empty")
        return
      }
      let config = MisttyConfig.current.restore
      windowsStore.restore(from: snapshot, config: config)
      let totalSessions = snapshot.windows.flatMap(\.sessions).count
      DebugLog.shared.log(
        "restore",
        "decoded snapshot: restored \(totalSessions) sessions")
    } catch {
      DebugLog.shared.log("restore", "decode failed: \(error)")
    }
  }
}
