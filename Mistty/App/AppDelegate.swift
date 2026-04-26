import AppKit
import Foundation
import MisttyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `MisttyApp.init()` right after the adaptor materializes us.
  var store: SessionStore!

  /// Strong ref so the observer outlives init. Set by `MisttyApp.init()`.
  var observer: StateRestorationObserver?

  private static let coderKey = "workspace"

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    guard let store else {
      DebugLog.shared.log("restore", "willEncode: no store wired")
      return
    }
    let snapshot = store.takeSnapshot()
    do {
      let data = try JSONEncoder().encode(snapshot)
      coder.encode(data as NSData, forKey: Self.coderKey)
      DebugLog.shared.log(
        "restore",
        "encoded snapshot: \(snapshot.sessions.count) sessions, \(data.count) bytes")
    } catch {
      DebugLog.shared.log("restore", "encode failed: \(error)")
    }
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    guard let store else {
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
      store.restore(from: snapshot, config: config)
      DebugLog.shared.log(
        "restore",
        "decoded snapshot: restored \(snapshot.sessions.count) sessions")
    } catch {
      DebugLog.shared.log("restore", "decode failed: \(error)")
    }
  }
}
