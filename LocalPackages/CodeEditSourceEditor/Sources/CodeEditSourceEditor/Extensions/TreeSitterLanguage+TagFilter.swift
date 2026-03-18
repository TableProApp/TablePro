//
//  TreeSitterLanguage+TagFilter.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/25/24.
//

import CodeEditLanguages

extension TreeSitterLanguage {
    fileprivate static let relevantLanguages: Set<String> = [
        CodeLanguage.html.id.rawValue,
        CodeLanguage.javascript.id.rawValue,
        CodeLanguage.typescript.id.rawValue,
        CodeLanguage.jsx.id.rawValue,
        CodeLanguage.tsx.id.rawValue
    ]

    func shouldProcessTags() -> Bool {
        return Self.relevantLanguages.contains(self.rawValue)
    }
}
