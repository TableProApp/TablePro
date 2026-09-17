import Foundation
import SwiftTreeSitter
import TreeSitterGrammars

/// A language the editor can highlight, and everything the editor needs to do it.
public struct CodeLanguage: Hashable, Sendable {
    /// Which grammar parses this language.
    public let id: GrammarID

    /// The directory under `Queries` holding this language's queries, and the parser it shares.
    ///
    /// JSX reads the JavaScript parser and the JavaScript query directory, so this is not always `id.rawValue`.
    public let grammarName: String

    /// File extensions that name this language.
    public let extensions: Set<String>

    /// The prefix that comments out one line, empty when the language has no line comment.
    public let lineCommentString: String

    /// The opening and closing strings of a block comment, both empty when the language has none.
    public let blockCommentStrings: (String, String)

    /// Query files to load ahead of `highlights.scm`, without their extension.
    public let additionalQueries: Set<String>

    private init(
        id: GrammarID,
        grammarName: String,
        extensions: Set<String>,
        lineCommentString: String,
        blockCommentStrings: (String, String),
        additionalQueries: Set<String> = []
    ) {
        self.id = id
        self.grammarName = grammarName
        self.extensions = extensions
        self.lineCommentString = lineCommentString
        self.blockCommentStrings = blockCommentStrings
        self.additionalQueries = additionalQueries
    }

    /// The parser for this language, or `nil` for plain text.
    public var language: Language? {
        guard let parser else { return nil }
        return Language(language: parser)
    }

    /// The URL of this language's `highlights.scm`, or `nil` for plain text.
    public var queryURL: URL? { queryURL(for: "highlights") }

    /// The URL of one of this language's query files, named without its extension.
    ///
    /// The lookup goes through `Bundle`, never through `resourceURL` plus a path: only `Bundle` knows whether
    /// this bundle keeps its resources at the root or under `Contents/Resources`, and the two layouts differ
    /// by toolchain.
    public func queryURL(for query: String) -> URL? {
        guard id != .plainText else { return nil }
        return Bundle.module.url(
            forResource: query,
            withExtension: "scm",
            subdirectory: "Queries/tree-sitter-\(grammarName)"
        )
    }

    private var parser: OpaquePointer? {
        switch id {
        case .bash: tree_sitter_bash()
        case .javascript, .jsx: tree_sitter_javascript()
        case .json: tree_sitter_json()
        case .sql: tree_sitter_sql()
        case .plainText: nil
        }
    }

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public extension CodeLanguage {
    /// Every language with a grammar behind it, in the order a picker would list them.
    static let allLanguages: [CodeLanguage] = [.bash, .javascript, .jsx, .json, .sql]

    static let bash = CodeLanguage(
        id: .bash,
        grammarName: "bash",
        extensions: ["sh", "bash"],
        lineCommentString: "#",
        blockCommentStrings: (":'", "'")
    )

    static let javascript = CodeLanguage(
        id: .javascript,
        grammarName: "javascript",
        extensions: ["js", "cjs", "mjs"],
        lineCommentString: "//",
        blockCommentStrings: ("/*", "*/"),
        additionalQueries: ["injections"]
    )

    static let jsx = CodeLanguage(
        id: .jsx,
        grammarName: "javascript",
        extensions: ["jsx"],
        lineCommentString: "//",
        blockCommentStrings: ("/*", "*/"),
        additionalQueries: ["highlights-jsx", "injections"]
    )

    static let json = CodeLanguage(
        id: .json,
        grammarName: "json",
        extensions: ["json"],
        lineCommentString: "",
        blockCommentStrings: ("", "")
    )

    static let sql = CodeLanguage(
        id: .sql,
        grammarName: "sql",
        extensions: ["sql"],
        lineCommentString: "--",
        blockCommentStrings: ("/*", "*/")
    )

    /// Plain text: no parser, no queries, no comment syntax.
    static let `default` = CodeLanguage(
        id: .plainText,
        grammarName: "plaintext",
        extensions: ["txt"],
        lineCommentString: "",
        blockCommentStrings: ("", "")
    )
}
