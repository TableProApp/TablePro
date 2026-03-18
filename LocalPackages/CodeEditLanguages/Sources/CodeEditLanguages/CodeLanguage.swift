//
//  CodeLanguage.swift
//  CodeEditTextView/CodeLanguage
//
//  Created by Lukas Pistrol on 25.05.22.
//

import Foundation
import SwiftTreeSitter
import TreeSitterGrammars

/// A structure holding metadata for code languages
public struct CodeLanguage {
    internal init(
        id: TreeSitterLanguage,
        tsName: String,
        extensions: Set<String>,
        lineCommentString: String,
        rangeCommentStrings: (String, String),
        documentationCommentStrings: Set<DocumentationComments> = [],
        parentURL: URL? = nil,
        highlights: Set<String>? = nil,
        additionalIdentifiers: Set<String> = []
    ) {
        self.id = id
        self.tsName = tsName
        self.extensions = extensions
        self.lineCommentString = lineCommentString
        self.rangeCommentStrings = rangeCommentStrings
        self.documentationCommentStrings = documentationCommentStrings
        self.parentQueryURL = parentURL
        self.additionalHighlights = highlights
        self.additionalIdentifiers = additionalIdentifiers
    }

    /// The ID of the language
    public let id: TreeSitterLanguage

    /// The display name of the language
    public let tsName: String

    /// A set of file extensions for the language
    ///
    /// In special cases this can also be a file name
    /// (e.g `Dockerfile`, `Makefile`)
    public let extensions: Set<String>

    /// The leading string of a comment line
    public let lineCommentString: String

    /// The leading and trailing string of a multi-line comment
    public let rangeCommentStrings: (String, String)

    /// The leading (and trailing, if there is one) string of a documentation comment
    public let documentationCommentStrings: Set<DocumentationComments>

    /// The query URL of a language this language inherits from. (e.g.: C for C++)
    public let parentQueryURL: URL?

    /// Additional highlight file names (e.g.: JSX for JavaScript)
    public let additionalHighlights: Set<String>?

    /// The query URL for the language if available
    public var queryURL: URL? {
        queryURL()
    }

    /// The bundle's resource URL
    internal var resourceURL: URL? = Bundle.module.resourceURL

    /// A set of aditional identifiers to use for things like shebang matching.
    public let additionalIdentifiers: Set<String>

    /// The tree-sitter language for the language if available
    public var language: Language? {
        guard let tsLanguage = tsLanguage else { return nil }
        return Language(language: tsLanguage)
    }

    internal func queryURL(for highlights: String = "highlights") -> URL? {
        return resourceURL?
            .appendingPathComponent("Resources/tree-sitter-\(tsName)/\(highlights).scm")
    }

    /// Gets the TSLanguage from `tree-sitter` — only SQL, Bash, and JavaScript are supported
    private var tsLanguage: OpaquePointer? {
        switch id {
        case .bash:
            return tree_sitter_bash()
        case .javascript, .jsx:
            return tree_sitter_javascript()
        case .sql:
            return tree_sitter_sql()
        default:
            return nil
        }
    }
}

extension CodeLanguage: Hashable {
    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool {
        return lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum DocumentationComments: Hashable {
    public static func == (lhs: DocumentationComments, rhs: DocumentationComments) -> Bool {
        switch lhs {
        case .single(let lhsString):
            switch rhs {
            case .single(let rhsString):
                return lhsString == rhsString
            case .pair:
                return false
            }
        case .pair(let lhsPair):
            switch rhs {
            case .single:
                return false
            case .pair(let rhsPair):
                return lhsPair.0 == rhsPair.0 && lhsPair.1 == rhsPair.1
            }
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .single(let string):
            hasher.combine(string)
        case .pair(let pair):
            hasher.combine(pair.0)
            hasher.combine(pair.1)
        }
    }

    case single(String)
    case pair((String, String))
}
