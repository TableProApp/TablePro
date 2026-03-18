//
//  CodeLanguage+Definitions.swift
//
//
//  Created by Lukas Pistrol on 15.01.23.
//

import Foundation

public extension CodeLanguage {

    /// An array of all language structures.
    static let allLanguages: [CodeLanguage] = [
        .bash,
        .javascript,
        .jsx,
        .sql
    ]

    /// A language structure for `Bash`
    static let bash: CodeLanguage = .init(
        id: .bash,
        tsName: "bash",
        extensions: ["sh", "bash"],
        lineCommentString: "#",
        rangeCommentStrings: (":'", "'")
    )

    /// A language structure for `HTML`
    static let html: CodeLanguage = .init(
        id: .html,
        tsName: "html",
        extensions: ["html", "htm", "shtml"],
        lineCommentString: "",
        rangeCommentStrings: ("<!--", "-->"),
        highlights: ["injections"]
    )

    /// A language structure for `JavaScript`
    static let javascript: CodeLanguage = .init(
        id: .javascript,
        tsName: "javascript",
        extensions: ["js", "cjs", "mjs"],
        lineCommentString: "//",
        rangeCommentStrings: ("/*", "*/"),
        documentationCommentStrings: [.pair(("/**", "*/"))],
        highlights: ["injections"],
        additionalIdentifiers: ["node", "deno"]
    )

    /// A language structure for `JSDoc`
    static let jsdoc: CodeLanguage = .init(
        id: .jsdoc,
        tsName: "jsdoc",
        extensions: [],
        lineCommentString: "",
        rangeCommentStrings: ("/**", "*/")
    )

    /// A language structure for `JSX`
    static let jsx: CodeLanguage = .init(
        id: .jsx,
        tsName: "javascript",
        extensions: ["jsx"],
        lineCommentString: "//",
        rangeCommentStrings: ("/*", "*/"),
        highlights: ["highlights-jsx", "injections"]
    )

    /// A language structure for `SQL`
    static let sql: CodeLanguage = .init(
        id: .sql,
        tsName: "sql",
        extensions: ["sql"],
        lineCommentString: "--",
        rangeCommentStrings: ("/*", "*/")
    )

    /// A language structure for `TSX`
    static let tsx: CodeLanguage = .init(
        id: .tsx,
        tsName: "typescript",
        extensions: ["tsx"],
        lineCommentString: "//",
        rangeCommentStrings: ("/*", "*/"),
        parentURL: CodeLanguage.jsx.queryURL
    )

    /// A language structure for `Typescript`
    static let typescript: CodeLanguage = .init(
        id: .typescript,
        tsName: "typescript",
        extensions: ["ts", "cts", "mts"],
        lineCommentString: "//",
        rangeCommentStrings: ("/*", "*/"),
        parentURL: CodeLanguage.javascript.queryURL
    )

    /// The default language (plain text)
    static let `default`: CodeLanguage = .init(
        id: .plainText,
        tsName: "PlainText",
        extensions: ["txt"],
        lineCommentString: "",
        rangeCommentStrings: ("", "")
    )
}
