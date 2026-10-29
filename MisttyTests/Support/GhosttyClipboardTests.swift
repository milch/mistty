import GhosttyKit
import XCTest
@testable import Mistty

final class GhosttyClipboardTests: XCTestCase {
  func test_payload_servesTextPlainWhenRequested() {
    XCTAssertEqual(
      GhosttyClipboard.payload(requested: ["text/plain"], list: false, pasteboardText: "hi"),
      ClipboardPayload(
        contents: [.init(mime: "text/plain", data: Data("hi".utf8))], available: []))
  }

  func test_payload_nilWhenNothingServableAndNoListing() {
    XCTAssertNil(
      GhosttyClipboard.payload(requested: ["image/png"], list: false, pasteboardText: "hi"))
    XCTAssertNil(
      GhosttyClipboard.payload(requested: ["text/plain"], list: false, pasteboardText: nil))
    XCTAssertNil(
      GhosttyClipboard.payload(requested: ["text/plain"], list: false, pasteboardText: ""))
  }

  func test_payload_listingWithoutContents() {
    let withText = GhosttyClipboard.payload(requested: [], list: true, pasteboardText: "hi")
    XCTAssertEqual(withText?.contents, [])
    XCTAssertEqual(withText?.available, ["text/plain"])

    let empty = GhosttyClipboard.payload(requested: [], list: true, pasteboardText: nil)
    XCTAssertNotNil(empty)
    XCTAssertEqual(empty?.contents, [])
    XCTAssertEqual(empty?.available, [])
  }

  func test_payload_dedupesRepeatedMimes() {
    let payload = GhosttyClipboard.payload(
      requested: ["text/plain", "text/plain"], list: false, pasteboardText: "x")
    XCTAssertEqual(payload?.contents.count, 1)
  }

  func test_contents_readsExactlyLenBytes_withoutNulTerminator() {
    let bytes: [CChar] = Array("abcXYZ".utf8).map { CChar(bitPattern: $0) }
    let result = "text/plain".withCString { mime in
      bytes.withUnsafeBufferPointer { buf in
        var content = ghostty_clipboard_content_s(mime: mime, data: buf.baseAddress, len: 3)
        return withUnsafePointer(to: &content) { GhosttyClipboard.contents($0, count: 1) }
      }
    }
    XCTAssertEqual(result, [.init(mime: "text/plain", data: Data("abc".utf8))])
  }

  func test_contents_zeroLengthYieldsEmptyData() {
    let result = "text/plain".withCString { mime in
      var content = ghostty_clipboard_content_s(mime: mime, data: nil, len: 0)
      return withUnsafePointer(to: &content) { GhosttyClipboard.contents($0, count: 1) }
    }
    XCTAssertEqual(result, [.init(mime: "text/plain", data: Data())])
  }

  func test_text_picksTextPlainEntry() {
    let png = ClipboardContent(mime: "image/png", data: Data([0x89, 0x50]))
    XCTAssertEqual(
      GhosttyClipboard.text(in: [png, .init(mime: "text/plain", data: Data("x".utf8))]), "x")
    XCTAssertNil(GhosttyClipboard.text(in: [png]))
  }

  func test_withComplete_roundTripsPayload() {
    let payload = ClipboardPayload(
      contents: [
        .init(mime: "text/plain", data: Data("hello".utf8)),
        .init(mime: "image/png", data: Data([0x00, 0x01, 0x00])),
        .init(mime: "text/html", data: Data()),
      ],
      available: ["text/plain", "image/png"])
    GhosttyClipboard.withComplete(payload, confirmed: true) { c in
      XCTAssertEqual(
        GhosttyClipboard.contents(c.pointee.contents, count: c.pointee.contents_len),
        payload.contents)
      XCTAssertEqual(
        GhosttyClipboard.strings(c.pointee.available, count: c.pointee.available_len),
        payload.available)
      XCTAssertTrue(c.pointee.confirmed)
      XCTAssertFalse(c.pointee.remember)
    }
  }
}
