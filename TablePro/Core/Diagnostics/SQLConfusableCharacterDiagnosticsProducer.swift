//
//  SQLConfusableCharacterDiagnosticsProducer.swift
//  TablePro
//

import Foundation

struct SQLConfusableCharacterDiagnosticsProducer: QueryDiagnosticsProducing {
    let rules: SQLLexicalRules

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= QueryDiagnosticsLimits.maximumDocumentLength else { return [] }

        return SQLConfusableCharacterScanner.scan(source, rules: rules).map { match in
            QueryDiagnostic(range: match.range, message: match.character.message, severity: .warning)
        }
    }
}
