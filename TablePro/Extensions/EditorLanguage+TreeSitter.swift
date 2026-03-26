//
//  EditorLanguage+TreeSitter.swift
//  TablePro
//

import TableProPluginKit

extension EditorLanguage {
    var codeBlockTag: String {
        switch self {
        case .sql: return "sql"
        case .javascript: return "javascript"
        case .bash: return "bash"
        case .custom(let name): return name
        }
    }
}
