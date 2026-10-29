import Foundation
import GhosttyKit

struct ClipboardContent: Equatable, Sendable {
  let mime: String
  let data: Data
}

/// A clipboard read completion owned by Swift. libghostty's C contents are
/// only borrowed for the duration of a callback, so they're copied into this
/// before any hop (e.g. to the main actor for a permission prompt).
struct ClipboardPayload: Equatable, Sendable {
  var contents: [ClipboardContent]
  var available: [String]
}

/// Bridges libghostty's multi-MIME clipboard C API. Mistty only serves the
/// pasteboard's plain-text representation.
enum GhosttyClipboard {
  static let textMime = "text/plain"

  /// The core's `isTextMime` names, matched exactly (case-sensitive, no
  /// parameter parsing).
  static let textMimes: Set<String> = [
    textMime, "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING",
  ]

  enum ConfirmRoute: Equatable {
    case autoConfirm
    case askReadPermission
  }

  /// Pastes are user-initiated and writes only change the clipboard, so
  /// neither goes through the read-permission system. Everything else
  /// discloses clipboard contents (or types) to the program; unknown requests
  /// fail closed.
  static func confirmRoute(for request: ghostty_clipboard_request_e) -> ConfirmRoute {
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
      GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
      .autoConfirm
    default:
      .askReadPermission
    }
  }

  /// The completion for a read request asking for `requested` MIME types
  /// (plus the available-types listing when `list`). nil when there is
  /// nothing to serve and no listing was requested.
  static func payload(
    requested: [String], list: Bool, pasteboardText: String?
  ) -> ClipboardPayload? {
    let text = pasteboardText.flatMap { $0.isEmpty ? nil : $0 }
    var contents: [ClipboardContent] = []
    if let text, requested.contains(textMime) {
      contents.append(ClipboardContent(mime: textMime, data: Data(text.utf8)))
    }
    if contents.isEmpty && !list { return nil }
    let available = list && text != nil ? [textMime] : []
    return ClipboardPayload(contents: contents, available: available)
  }

  /// Copies `count` borrowed C entries. `data` is length-delimited, not
  /// NUL-terminated.
  static func contents(
    _ ptr: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
  ) -> [ClipboardContent] {
    guard let ptr, count > 0 else { return [] }
    return UnsafeBufferPointer(start: ptr, count: count).compactMap { entry in
      guard let mime = entry.mime else { return nil }
      let data =
        if entry.len > 0, let bytes = entry.data {
          Data(bytes: bytes, count: entry.len)
        } else {
          Data()
        }
      return ClipboardContent(mime: String(cString: mime), data: data)
    }
  }

  static func strings(_ ptr: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> [String] {
    guard let ptr, count > 0 else { return [] }
    return UnsafeBufferPointer(start: ptr, count: count).compactMap {
      $0.map(String.init(cString:))
    }
  }

  /// The text to write: the exact `text/plain` entry if present, otherwise
  /// the first entry under any of `textMimes`.
  static func text(in contents: [ClipboardContent]) -> String? {
    let entry =
      contents.first { $0.mime == textMime } ?? contents.first { textMimes.contains($0.mime) }
    return entry.map { String(decoding: $0.data, as: UTF8.self) }
  }

  /// Exposes `payload` as a `ghostty_clipboard_complete_s`. The C memory is
  /// only valid for the duration of `body`.
  static func withComplete<R>(
    _ payload: ClipboardPayload, confirmed: Bool,
    _ body: (UnsafePointer<ghostty_clipboard_complete_s>) -> R
  ) -> R {
    var strings: [UnsafeMutablePointer<CChar>] = []
    var buffers: [UnsafeMutablePointer<CChar>] = []
    defer {
      strings.forEach { free($0) }
      buffers.forEach { $0.deallocate() }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for entry in payload.contents {
      guard let mime = strdup(entry.mime) else { continue }
      strings.append(mime)
      let bytes = UnsafeMutablePointer<CChar>.allocate(capacity: max(entry.data.count, 1))
      buffers.append(bytes)
      entry.data.withUnsafeBytes { src in
        UnsafeMutableRawBufferPointer(start: bytes, count: src.count).copyMemory(from: src)
      }
      cContents.append(
        ghostty_clipboard_content_s(mime: mime, data: bytes, len: entry.data.count))
    }

    var cAvailable: [UnsafePointer<CChar>?] = []
    for mime in payload.available {
      guard let str = strdup(mime) else { continue }
      strings.append(str)
      cAvailable.append(UnsafePointer(str))
    }

    return cContents.withUnsafeBufferPointer { contentsBuf in
      cAvailable.withUnsafeBufferPointer { availableBuf in
        var complete = ghostty_clipboard_complete_s(
          contents: contentsBuf.baseAddress,
          contents_len: contentsBuf.count,
          available: availableBuf.baseAddress,
          available_len: availableBuf.count,
          confirmed: confirmed,
          remember: false)
        return withUnsafePointer(to: &complete) { body($0) }
      }
    }
  }

  static func complete(
    _ surface: ghostty_surface_t, payload: ClipboardPayload,
    state: UnsafeMutableRawPointer, confirmed: Bool
  ) {
    withComplete(payload, confirmed: confirmed) {
      ghostty_surface_complete_clipboard_request(surface, $0, state)
    }
  }
}
