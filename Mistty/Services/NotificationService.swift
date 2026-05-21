import AppKit
import Foundation
import UserNotifications

/// Resolve the title shown in a macOS notification. OSC 9 carries no title,
/// so fall back through the emitting pane's process title, then the session
/// label, then a constant. Whitespace-only values are treated as empty.
func resolveNotificationTitle(
  rawTitle: String, processTitle: String?, sessionLabel: String
) -> String {
  let raw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  if !raw.isEmpty { return raw }
  if let processTitle = processTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
    !processTitle.isEmpty
  {
    return processTitle
  }
  let label = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
  if !label.isEmpty { return label }
  return "Mistty"
}
