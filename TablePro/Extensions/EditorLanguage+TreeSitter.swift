//
//  EditorLanguage+TreeSitter.swift
//  TablePro
//

import CodeEditLanguages
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

    var codeBlockTag: String {
        switch self {
        case .sql: return "sql"
        case .javascript: return "javascript"
        case .bash: return "bash"
        case .custom(let name): return name
        }
    }
}
