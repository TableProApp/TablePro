import Foundation

/// Picks the DM8 protocol framing path for a statement.
///
/// This is a hint, not a verdict. DM8 commits to a framing path before the response arrives,
/// so something has to guess, but the guess must never decide what the user sees: the bridge
/// converts whatever columns and rows came back either way. A statement misjudged here costs
/// one protocol round trip shape, not its result.
enum DamengStatementClassifier {
    private static let resultKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW", "VALUES", "WITH"
    ]

    private static let readOnlyKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW"
    ]

    static func likelyReturnsRows(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return resultKeywords.contains(keyword)
    }

    /// Whether running this statement twice is the same as running it once, which is what
    /// decides if it may be sent again on a rebuilt connection.
    ///
    /// The list is an allowlist and deliberately shorter than `resultKeywords`: `WITH` and
    /// `VALUES` can head a statement that writes, and a replayed write may apply twice
    /// because the abandoned attempt could already have committed.
    static func isReadOnly(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return readOnlyKeywords.contains(keyword)
    }

    private static func firstKeyword(_ query: String) -> String? {
        var remaining = query[...]
        while true {
            remaining = remaining.drop { $0.isWhitespace || $0 == "(" || $0 == ";" || $0 == "\u{FEFF}" }
            if remaining.hasPrefix("--") {
                guard let newline = remaining.firstIndex(where: \.isNewline) else { return nil }
                remaining = remaining[remaining.index(after: newline)...]
            } else if remaining.hasPrefix("/*") {
                remaining = skippingBlockComment(remaining.dropFirst(2))
            } else {
                let keyword = remaining.prefix { $0.isLetter || $0 == "_" }
                return keyword.isEmpty ? nil : keyword.uppercased()
            }
        }
    }

    private static func skippingBlockComment(_ body: Substring) -> Substring {
        var remaining = body
        var depth = 1
        while let character = remaining.first {
            remaining = remaining.dropFirst()
            if character == "/", remaining.first == "*" {
                remaining = remaining.dropFirst()
                depth += 1
            } else if character == "*", remaining.first == "/" {
                remaining = remaining.dropFirst()
                depth -= 1
                if depth == 0 { return remaining }
            }
        }
        return remaining
    }
}
