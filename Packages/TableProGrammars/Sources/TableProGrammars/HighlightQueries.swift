import Foundation
import SwiftTreeSitter

/// Compiled tree-sitter highlight queries, built once per language and held for the life of the process.
///
/// Compiling a query parses the `.scm` source against the grammar, which is why this is a cache rather than a
/// free function: the editor asks for the same five queries on every document it opens.
public final class HighlightQueries: @unchecked Sendable {
    public static let shared = HighlightQueries()

    private let lock = NSLock()
    private var compiled: [GrammarID: Query] = [:]

    private init() {}

    /// The highlight query for a language, or `nil` for plain text and for a query that does not compile.
    public func query(for id: GrammarID) -> Query? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[id] { return cached }
        guard let query = Self.compile(id) else { return nil }
        compiled[id] = query
        return query
    }

    private static func compile(_ id: GrammarID) -> Query? {
        guard let codeLanguage = CodeLanguage.allLanguages.first(where: { $0.id == id }),
              let language = codeLanguage.language,
              let source = querySource(for: codeLanguage) else { return nil }
        return try? Query(language: language, data: source)
    }

    /// The language's own `highlights.scm`, preceded by the extra queries it names.
    ///
    /// Order matters: tree-sitter takes the first pattern that matches, so `highlights-jsx.scm` has to be read
    /// before the JavaScript highlights it narrows.
    private static func querySource(for codeLanguage: CodeLanguage) -> Data? {
        let urls = codeLanguage.additionalQueries
            .sorted()
            .compactMap { codeLanguage.queryURL(for: $0) }
            + [codeLanguage.queryURL].compactMap { $0 }
        let source = urls
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return source.isEmpty ? nil : Data(source.utf8)
    }
}
