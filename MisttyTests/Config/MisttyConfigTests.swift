import XCTest
@testable import Mistty

final class MisttyConfigTests: XCTestCase {
    func test_defaultConfig() {
        let config = MisttyConfig.default
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.fontFamily, "monospace")
    }

    func test_parsesValidTOML() throws {
        let toml = """
        font_size = 16
        font_family = "JetBrains Mono"
        """
        let config = try MisttyConfig.parse(toml)
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.fontFamily, "JetBrains Mono")
    }

    func test_missingKeysUseDefaults() throws {
        let config = try MisttyConfig.parse("")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.fontFamily, "monospace")
    }

    func test_invalidTOMLThrows() {
        XCTAssertThrowsError(try MisttyConfig.parse("font_size = !!!invalid"))
    }
}
