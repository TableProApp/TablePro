//
//  EditorLanguage+TreeSitter.swift
//  TablePro
//

import TableProGrammars
import TableProPluginKit

extension EditorLanguage {
    var treeSitterLanguage: CodeLanguage {
        switch self {
        case .sql: return .sql
        case .javascript: return .javascript
        case .bash: return .bash
        case .custom: return .default
        }
    }

    /// What starts a line comment in a query tab of this language, or an empty string when the
    /// language has none.
    var lineCommentMarker: String {
        treeSitterLanguage.lineCommentString
    }

    var codeBlockTag: String {
        switch self {
        case .sql: return "sql"
        case .javascript: return "javascript"
        case .bash: return "bash"
        case .custom(let name): return name
        }
    }
}
