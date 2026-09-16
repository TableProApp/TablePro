//
//  SQLCompletionCasing.swift
//  TablePro
//
//  Presentation case for completion items, decided from the typed prefix.
//

import Foundation

/// Whether a completion item's spelling may follow the typed prefix.
///
/// `.fixed` is the default because most of what the popup offers is a name the server chose:
/// tables, columns, schemas, aliases, value literals, saved favorites, MongoDB pipeline stages and
/// plugin-supplied statement vocabulary. Re-casing any of those changes what the statement means.
/// Only vocabulary the engine matches case-insensitively opts in.
enum SQLCompletionCaseFolding {
    case fixed
    case caseInsensitive
}

/// How keywords and built-in functions are cased when completed.
///
/// The four values are psql's `COMP_KEYWORD_CASE`. The two `matchTyped` values differ only in the
/// case they fall back to when the prefix carries no cased character, which happens whenever the
/// popup is invoked on an empty token.
enum SQLKeywordCase: String, Codable, CaseIterable, Sendable {
    case upper
    case lower
    case matchTypedElseUpper
    case matchTypedElseLower

    static let `default` = SQLKeywordCase.matchTypedElseUpper

    var displayName: String {
        switch self {
        case .upper: return String(localized: "UPPERCASE")
        case .lower: return String(localized: "lowercase")
        case .matchTypedElseUpper: return String(localized: "Match what I type, otherwise UPPERCASE")
        case .matchTypedElseLower: return String(localized: "Match what I type, otherwise lowercase")
        }
    }

    /// Whether typed text is rewritten as the user types. Only the two absolute values do; a
    /// `matchTyped` value describes what a completion inserts and never touches what was typed.
    var rewritesTypedText: Bool {
        switch self {
        case .upper, .lower: return true
        case .matchTypedElseUpper, .matchTypedElseLower: return false
        }
    }

    /// The case `Format SQL` and the as-you-type rewriter apply, ignoring any typed prefix.
    var prefersUppercase: Bool {
        switch self {
        case .upper, .matchTypedElseUpper: return true
        case .lower, .matchTypedElseLower: return false
        }
    }
}

enum SQLCompletionCasing {
    /// The case a completion takes for `typedPrefix` under `policy`.
    ///
    /// Decided from the first *cased* scalar of the prefix and nothing else, which is psql's rule
    /// (`pg_strdup_keyword_case` branches on `islower(ref[0])` alone). A leading capital therefore
    /// reads as uppercase intent rather than as a Capitalised arm, matching Vim's `infercase` and
    /// Emacs' `dabbrev`, and a mixed prefix like `sElE` follows its first letter rather than trying
    /// to reproduce itself.
    static func resolvedCase(typedPrefix: String, policy: SQLKeywordCase) -> Bool {
        switch policy {
        case .upper: return true
        case .lower: return false
        case .matchTypedElseUpper, .matchTypedElseLower:
            guard let scalar = typedPrefix.unicodeScalars.first(where: { $0.properties.isCased }) else {
                return policy.prefersUppercase
            }
            return !scalar.properties.isLowercase
        }
    }

    /// `text` folded to the resolved case as one phrase, so a multi-word keyword follows its first
    /// letter throughout and never comes back as `group BY`.
    ///
    /// `String.uppercased()` and `String.lowercased()` are the locale-independent pair. The
    /// `localized` and `NSString.lowercased(with:)` forms are not: under `tr_TR` they fold `INSERT`
    /// to `ınsert`, which no SQL engine knows. `String.capitalized` is wrong for a different
    /// reason: it lowercases the rest of every word, so it would destroy a candidate's own casing.
    static func folded(_ text: String, uppercase: Bool) -> String {
        uppercase ? text.uppercased() : text.lowercased()
    }

    /// `items` with every `.caseInsensitive` entry re-cased for `typedPrefix`.
    ///
    /// `label` and `insertText` are rewritten together, or the popup would offer one spelling and
    /// commit another. `filterText` is deliberately left alone: it is the canonical lowercase form
    /// every matcher compares against, and `matchedRanges` are offsets into it.
    static func applied(
        to items: [SQLCompletionItem],
        typedPrefix: String,
        policy: SQLKeywordCase
    ) -> [SQLCompletionItem] {
        let uppercase = resolvedCase(typedPrefix: typedPrefix, policy: policy)
        return items.map { item in
            guard item.caseFolding == .caseInsensitive else { return item }
            return item.recased(
                label: folded(item.label, uppercase: uppercase),
                insertText: folded(item.insertText, uppercase: uppercase)
            )
        }
    }
}
