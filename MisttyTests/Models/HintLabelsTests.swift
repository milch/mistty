import XCTest
@testable import Mistty

final class HintLabelsTests: XCTestCase {
  func test_singleMatch_singleChar() {
    let labels = HintLabels.generate(count: 1, alphabet: "asdf")
    XCTAssertEqual(labels, ["a"])
  }

  func test_lessThanAlphabet_allSingleChar() {
    let labels = HintLabels.generate(count: 3, alphabet: "asdf")
    XCTAssertEqual(labels, ["a", "s", "d"])
  }

  func test_moreThanAlphabet_usesTwoCharLabels() {
    // 5 matches, alphabet size 4. Reserve 1 prefix ("f") for 2-char labels.
    // 3 single-char: a, s, d. 2 two-char: fa, fs.
    let labels = HintLabels.generate(count: 5, alphabet: "asdf")
    XCTAssertEqual(labels, ["a", "s", "d", "fa", "fs"])
  }

  func test_exactSquareCapacity() {
    // alphabet size 2, 4 matches => 0 single-char, 4 two-char (aa, as, sa, ss)
    let labels = HintLabels.generate(count: 4, alphabet: "as")
    XCTAssertEqual(labels, ["aa", "as", "sa", "ss"])
  }

  func test_allLabelsUnique() {
    let labels = HintLabels.generate(count: 50, alphabet: "asdfghjkl")
    XCTAssertEqual(Set(labels).count, labels.count)
  }

  func test_zeroCount_emptyArray() {
    let labels = HintLabels.generate(count: 0, alphabet: "asdf")
    XCTAssertEqual(labels, [])
  }
}
