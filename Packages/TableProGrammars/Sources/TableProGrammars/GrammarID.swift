import Foundation

/// The grammars TablePro compiles.
///
/// Every case is backed by a parser in the `TreeSitterGrammars` target, so a case can always be resolved to a parser
/// and a highlight query. `plainText` is the absence of a grammar and is the only case that resolves to neither.
public enum GrammarID: String, CaseIterable, Sendable {
    case bash
    case javascript
    case jsx
    case json
    case sql
    case plainText
}
