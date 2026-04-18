import AppKit
import SwiftUI

/// Parses and validates `#rrggbb` / `#rrggbbaa` hex color strings into SwiftUI colors.
enum HexColor {
  /// Returns true if the string is a valid 6- or 8-digit hex color, with an optional `#`.
  static func isValid(_ string: String) -> Bool {
    parseComponents(string) != nil
  }

  /// Parses the string into a SwiftUI Color. Returns nil for malformed input.
  static func parse(_ string: String) -> Color? {
    guard let (r, g, b, a) = parseComponents(string) else { return nil }
    return Color(red: r, green: g, blue: b, opacity: a)
  }

  private static func parseComponents(_ string: String) -> (Double, Double, Double, Double)? {
    var hex = string.hasPrefix("#") ? String(string.dropFirst()) : string
    guard hex.count == 6 || hex.count == 8 else { return nil }
    if hex.count == 6 { hex += "ff" }
    guard let value = UInt64(hex, radix: 16) else { return nil }
    let r = Double((value >> 24) & 0xff) / 255.0
    let g = Double((value >> 16) & 0xff) / 255.0
    let b = Double((value >> 8) & 0xff) / 255.0
    let a = Double(value & 0xff) / 255.0
    return (r, g, b, a)
  }
}
