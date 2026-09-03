import Foundation

/// Finds the wake phrase inside a running transcript.
///
/// The glasses microphone is 8 kHz — phone-call quality — so the recognizer
/// mishears things. "hey jarvis" comes back as "hey jarvis", "hey jarvas",
/// "hey jervis", "a jarvis". Matching is therefore fuzzy: each word is allowed
/// a small edit distance that scales with its length.
enum WakeWord {
    static let defaultPhrase = "hey jarvis"

    struct Match {
        /// Everything said after the wake phrase, which is the command itself.
        let remainder: String
    }

    /// Looks for `phrase` in `transcript`. Returns the text that followed it.
    static func find(_ phrase: String, in transcript: String) -> Match? {
        let phraseWords = normalize(phrase)
        let spokenWords = normalize(transcript)
        guard !phraseWords.isEmpty, spokenWords.count >= phraseWords.count else { return nil }

        // Scan from the end so a repeated wake word uses the most recent one.
        for start in stride(from: spokenWords.count - phraseWords.count, through: 0, by: -1) {
            let window = Array(spokenWords[start ..< start + phraseWords.count])
            guard zip(window, phraseWords).allSatisfy(isCloseEnough) else { continue }
            let remainder = spokenWords[(start + phraseWords.count)...].joined(separator: " ")
            return Match(remainder: remainder)
        }
        return nil
    }

    // MARK: - Matching

    private static func isCloseEnough(_ spoken: String, _ target: String) -> Bool {
        if spoken == target { return true }
        // One typo for short words, two for longer ones. "hey" must be near
        // exact; "jarvis" can lose a letter or two, which it does constantly at
        // 8 kHz ("jarvas", "jervis"). Both words of the phrase must match, so
        // the phrase as a whole stays specific even with per-word slack.
        let tolerance = max(1, target.count / 3)
        return editDistance(spoken, target) <= tolerance
    }

    private static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Standard Levenshtein distance, two-row variant.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let source = Array(a), target = Array(b)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            for j in 1...target.count {
                let substitution = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}
