import XCTest

@testable import MisttyShared

final class IPCConstantsTests: XCTestCase {
  func test_variant_insideReleaseBundle_isEmpty() {
    XCTAssertEqual(
      MisttyIPC.buildVariantSuffix(
        forExecutablePath: "/Applications/Mistty.app/Contents/MacOS/Mistty"),
      "")
  }

  func test_variant_insideDevBundle_isDashDev() {
    XCTAssertEqual(
      MisttyIPC.buildVariantSuffix(
        forExecutablePath: "/Applications/Mistty-dev.app/Contents/MacOS/Mistty"),
      "-dev")
  }

  func test_variant_devCLI_resolvesDevSuffix() {
    XCTAssertEqual(
      MisttyIPC.buildVariantSuffix(
        forExecutablePath: "/Applications/Mistty-dev.app/Contents/MacOS/mistty-cli"),
      "-dev")
  }

  func test_variant_releaseCLI_resolvesEmpty() {
    XCTAssertEqual(
      MisttyIPC.buildVariantSuffix(
        forExecutablePath: "/Applications/Mistty.app/Contents/MacOS/mistty-cli"),
      "")
  }

  func test_variant_swiftBuildOutput_isEmpty() {
    XCTAssertEqual(
      MisttyIPC.buildVariantSuffix(
        forExecutablePath: "/Users/x/proj/.build/arm64-apple-macosx/debug/Mistty"),
      "")
  }

  func test_variant_nilPath_isEmpty() {
    XCTAssertEqual(MisttyIPC.buildVariantSuffix(forExecutablePath: nil), "")
  }

  func test_socketPath_envVarOverride_winsOverServerPath() {
    let envVar = MisttyIPC.socketPathEnvVar
    let previous = getenv(envVar).flatMap { String(cString: $0) }
    setenv(envVar, "/tmp/mistty-override-test.sock", 1)
    defer {
      if let previous {
        setenv(envVar, previous, 1)
      } else {
        unsetenv(envVar)
      }
    }
    XCTAssertEqual(MisttyIPC.socketPath, "/tmp/mistty-override-test.sock")
    XCTAssertNotEqual(MisttyIPC.serverSocketPath, "/tmp/mistty-override-test.sock")
  }

  func test_socketPath_withoutEnvVar_matchesServerPath() {
    let envVar = MisttyIPC.socketPathEnvVar
    let previous = getenv(envVar).flatMap { String(cString: $0) }
    unsetenv(envVar)
    defer {
      if let previous {
        setenv(envVar, previous, 1)
      }
    }
    XCTAssertEqual(MisttyIPC.socketPath, MisttyIPC.serverSocketPath)
  }

  // MARK: - Wire-error codec

  func test_encodeDecode_roundTripsCodeAndMessage() {
    let err = MisttyIPC.error(.entityNotFound, "Tab 5 not found")
    let data = MisttyIPC.encodeWireError(err)
    let decoded = MisttyIPC.decodeWireError(data)
    XCTAssertEqual(decoded?.code, .entityNotFound)
    XCTAssertEqual(decoded?.message, "Tab 5 not found")
  }

  func test_encode_foreignError_usesOperationFailedAndDescription() {
    let err = NSError(
      domain: "other", code: 99, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let decoded = MisttyIPC.decodeWireError(MisttyIPC.encodeWireError(err))
    XCTAssertEqual(decoded?.code, .operationFailed)
    XCTAssertEqual(decoded?.message, "boom")
  }

  func test_decode_plainText_returnsNil() {
    XCTAssertNil(MisttyIPC.decodeWireError(Data("Tab 5 not found".utf8)))
  }
}
