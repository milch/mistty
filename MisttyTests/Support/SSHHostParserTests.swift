import XCTest

@testable import Mistty

final class SSHHostParserTests: XCTestCase {
  func test_simpleHost() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh mybox"), "mybox")
  }

  func test_userAtHost() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh manu@mybox"), "mybox")
  }

  func test_withPortFlag() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh -p 2222 mybox"), "mybox")
  }

  func test_withPortFlagAndUser() {
    XCTAssertEqual(SSHHostParser.host(from: "ssh -p 2222 manu@dev.example.com"), "dev.example.com")
  }

  func test_customSSHBinaryPrefix() {
    XCTAssertEqual(SSHHostParser.host(from: "/usr/bin/ssh -A mybox"), "mybox")
  }

  func test_emptyReturnsNil() {
    XCTAssertNil(SSHHostParser.host(from: ""))
  }

  func test_noHostReturnsNil() {
    XCTAssertNil(SSHHostParser.host(from: "ssh -p 22"))
  }
}
