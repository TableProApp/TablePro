//
//  SQLConfusableCharacterDiagnosticsProducer.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

struct SQLConfusableCharacterDiagnosticsProducer: QueryDiagnosticsProducing {
    let grammar: SQLLexicalGrammar

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= QueryDiagnosticsLimits.maximumDocumentLength else { return [] }

        return SQLConfusableCharacterScanner.scan(source, grammar: grammar).map { match in
            QueryDiagnostic(range: match.range, message: match.character.message, severity: .warning)
        }
    }
}
