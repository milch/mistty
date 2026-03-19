import XCTest
@testable import Mistty

final class WordMotionTests: XCTestCase {

    // MARK: - Character classification

    func test_charClass_keyword() {
        XCTAssertEqual(WordMotion.charClass("a"), .keyword)
        XCTAssertEqual(WordMotion.charClass("Z"), .keyword)
        XCTAssertEqual(WordMotion.charClass("0"), .keyword)
        XCTAssertEqual(WordMotion.charClass("_"), .keyword)
    }

    func test_charClass_punctuation() {
        XCTAssertEqual(WordMotion.charClass("."), .punctuation)
        XCTAssertEqual(WordMotion.charClass("-"), .punctuation)
        XCTAssertEqual(WordMotion.charClass("/"), .punctuation)
        XCTAssertEqual(WordMotion.charClass("("), .punctuation)
    }

    func test_charClass_whitespace() {
        XCTAssertEqual(WordMotion.charClass(" "), .whitespace)
        XCTAssertEqual(WordMotion.charClass("\t"), .whitespace)
    }

    // MARK: - w motion (next word start)

    func test_w_simpleWords() {
        let result = WordMotion.nextWordStart(in: "hello world", from: 0, bigWord: false)
        XCTAssertEqual(result, 6)
    }

    func test_w_punctuationBoundary() {
        let result = WordMotion.nextWordStart(in: "foo.bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_w_punctuationToWord() {
        let result = WordMotion.nextWordStart(in: "foo.bar", from: 3, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_W_skipsPunctuation() {
        let result = WordMotion.nextWordStart(in: "foo.bar baz", from: 0, bigWord: true)
        XCTAssertEqual(result, 8)
    }

    func test_w_atEndOfLine_returnsNil() {
        let result = WordMotion.nextWordStart(in: "hello", from: 4, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - b motion (previous word start)

    func test_b_simpleWords() {
        let result = WordMotion.prevWordStart(in: "hello world", from: 6, bigWord: false)
        XCTAssertEqual(result, 0)
    }

    func test_b_punctuationBoundary() {
        let result = WordMotion.prevWordStart(in: "foo.bar", from: 4, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_B_skipsPunctuation() {
        let result = WordMotion.prevWordStart(in: "baz foo.bar", from: 8, bigWord: true)
        XCTAssertEqual(result, 4)
    }

    func test_b_atStartOfLine_returnsNil() {
        let result = WordMotion.prevWordStart(in: "hello", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - e motion (word end)

    func test_e_simpleWords() {
        let result = WordMotion.nextWordEnd(in: "hello world", from: 0, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_e_alreadyAtEnd_goesToNextWordEnd() {
        let result = WordMotion.nextWordEnd(in: "hello world", from: 4, bigWord: false)
        XCTAssertEqual(result, 10)
    }

    func test_e_punctuationBoundary() {
        let result = WordMotion.nextWordEnd(in: "foo.bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 2)
    }

    func test_E_skipsPunctuation() {
        let result = WordMotion.nextWordEnd(in: "foo.bar baz", from: 0, bigWord: true)
        XCTAssertEqual(result, 6)
    }

    // MARK: - ge motion (previous word end)

    func test_ge_simpleWords() {
        let result = WordMotion.prevWordEnd(in: "hello world", from: 6, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_ge_punctuationBoundary() {
        let result = WordMotion.prevWordEnd(in: "foo.bar", from: 4, bigWord: false)
        XCTAssertEqual(result, 3)
    }

    func test_ge_fromMidWord() {
        // "hello world" cursor at 8 ('r') -> should go to 4 ('o' in "hello")
        let result = WordMotion.prevWordEnd(in: "hello world", from: 8, bigWord: false)
        XCTAssertEqual(result, 4)
    }

    func test_ge_atStartOfLine_returnsNil() {
        let result = WordMotion.prevWordEnd(in: "hello", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    // MARK: - Edge cases

    func test_w_multipleSpaces() {
        let result = WordMotion.nextWordStart(in: "foo   bar", from: 0, bigWord: false)
        XCTAssertEqual(result, 6)
    }

    func test_w_emptyString() {
        let result = WordMotion.nextWordStart(in: "", from: 0, bigWord: false)
        XCTAssertNil(result)
    }

    func test_w_allWhitespace() {
        let result = WordMotion.nextWordStart(in: "     ", from: 0, bigWord: false)
        XCTAssertNil(result)
    }
}
