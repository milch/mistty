import Foundation

enum WordMotion {

    enum CharClass: Equatable {
        case keyword
        case punctuation
        case whitespace
    }

    static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .whitespace }
        if c.isLetter || c.isNumber || c == "_" { return .keyword }
        return .punctuation
    }

    private static func bigWordClass(_ c: Character) -> CharClass {
        c.isWhitespace ? .whitespace : .keyword
    }

    private static func classify(_ c: Character, bigWord: Bool) -> CharClass {
        bigWord ? bigWordClass(c) : charClass(c)
    }

    /// w/W: move to start of next word. Returns nil if at end of line.
    static func nextWordStart(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col < chars.count else { return nil }

        var i = col
        let startClass = classify(chars[i], bigWord: bigWord)

        // Step 1: skip current word (same class)
        while i < chars.count && classify(chars[i], bigWord: bigWord) == startClass {
            i += 1
        }

        // Step 2: skip whitespace
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }

        return i < chars.count ? i : nil
    }

    /// b/B: move to start of previous word. Returns nil if at start of line.
    static func prevWordStart(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col > 0 else { return nil }

        var i = col - 1

        // Step 1: skip whitespace
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }

        // Step 2: skip current word (same class) backward
        let wordClass = classify(chars[i], bigWord: bigWord)
        while i > 0 && classify(chars[i - 1], bigWord: bigWord) == wordClass {
            i -= 1
        }

        return i
    }

    /// e/E: move to end of current/next word. Returns nil if at end of line.
    static func nextWordEnd(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col < chars.count else { return nil }

        var i = col + 1  // Move at least one position
        guard i < chars.count else { return nil }

        // Step 1: skip whitespace
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }
        guard i < chars.count else { return nil }

        // Step 2: advance through current word
        let wordClass = classify(chars[i], bigWord: bigWord)
        while i + 1 < chars.count && classify(chars[i + 1], bigWord: bigWord) == wordClass {
            i += 1
        }

        return i
    }

    /// ge/gE: move to end of previous word. Returns nil if at start of line.
    static func prevWordEnd(in line: String, from col: Int, bigWord: Bool) -> Int? {
        let chars = Array(line)
        guard col > 0 else { return nil }

        var i = col - 1

        // Step 1: if we're mid-word (prev char same class as current), skip to word start then step back
        if col < chars.count && !chars[i].isWhitespace &&
            classify(chars[i], bigWord: bigWord) == classify(chars[col], bigWord: bigWord) {
            while i > 0 && classify(chars[i - 1], bigWord: bigWord) == classify(chars[col], bigWord: bigWord) {
                i -= 1
            }
            // Now at start of current word. Move back one more to get past it.
            i -= 1
        }

        guard i >= 0 else { return nil }

        // Step 2: skip whitespace
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }

        // At end of the previous word
        return i
    }
}
