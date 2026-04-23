import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    DebugLog.shared.log("restore", "willEncodeRestorableState fired")
  }

  func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
    DebugLog.shared.log("restore", "didDecodeRestorableState fired")
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    DebugLog.shared.log("restore", "applicationWillFinishLaunching")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DebugLog.shared.log("restore", "applicationDidFinishLaunching")
  }
}
