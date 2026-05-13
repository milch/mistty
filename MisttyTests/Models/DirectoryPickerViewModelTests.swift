import XCTest

@testable import Mistty

@MainActor
final class DirectoryPickerViewModelTests: XCTestCase {

  /// Build a temporary directory the test owns end-to-end, so the "create"
  /// resolver has a real parent on disk to work against.
  private func withTempDir(_ body: (URL) -> Void) {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mistty-dirpicker-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    body(tmp)
  }

  func test_typingExistingPathSurfacesAsDirectory() {
    withTempDir { tmp in
      let vm = DirectoryPickerViewModel()
      vm.updateQuery(tmp.path)
      XCTAssertEqual(vm.filteredItems.first?.resolvedURL?.path, tmp.path)
      if case .directory = vm.filteredItems.first { } else {
        XCTFail("existing path should surface as .directory")
      }
    }
  }

  func test_typingMissingPathWithExistingParentOffersCreate() {
    withTempDir { tmp in
      let missing = tmp.appendingPathComponent("newchild")
      let vm = DirectoryPickerViewModel()
      vm.updateQuery(missing.path)
      guard let first = vm.filteredItems.first else {
        return XCTFail("expected a create-new entry")
      }
      guard case .newDirectory(_, let url) = first else {
        return XCTFail("expected .newDirectory, got \(first)")
      }
      XCTAssertEqual(url.path, missing.path)
    }
  }

  func test_typingMissingPathWithMissingParentReturnsNothing() {
    let vm = DirectoryPickerViewModel()
    vm.updateQuery("/this/path/definitely/does/not/exist/anywhere")
    XCTAssertTrue(vm.filteredItems.isEmpty,
                  "unresolvable path with no parent shouldn't surface anything")
  }

  func test_confirmCreatesMissingDirectory() {
    withTempDir { tmp in
      let missing = tmp.appendingPathComponent("brand-new")
      let vm = DirectoryPickerViewModel()
      vm.updateQuery(missing.path)
      let confirmed = vm.confirmSelection()
      XCTAssertEqual(confirmed?.path, missing.path)
      var isDir: ObjCBool = false
      XCTAssertTrue(FileManager.default.fileExists(atPath: missing.path, isDirectory: &isDir))
      XCTAssertTrue(isDir.boolValue)
    }
  }

  func test_confirmReturnsNilWhenNothingMatches() {
    let vm = DirectoryPickerViewModel()
    vm.updateQuery("/no/such/parent/exists/anywhere")
    XCTAssertNil(vm.confirmSelection())
  }

  func test_emptyQueryShowsAllZoxideItemsWithNoCreateRow() {
    // No query → only zoxide-sourced items; no synthetic "create" row.
    let vm = DirectoryPickerViewModel()
    vm.updateQuery("")
    for item in vm.filteredItems {
      if case .newDirectory = item {
        return XCTFail("empty query shouldn't offer create-new")
      }
    }
  }

  func test_plainTextQueryDoesNotResolveAsPath() {
    let vm = DirectoryPickerViewModel()
    vm.updateQuery("notapathlikethis")
    // Without a `/` or `~`, the resolver must not generate a .newDirectory.
    for item in vm.filteredItems {
      if case .newDirectory = item {
        return XCTFail("plain text shouldn't trigger create-new")
      }
    }
  }
}
