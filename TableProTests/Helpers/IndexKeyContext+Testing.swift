//
//  IndexKeyContext+Testing.swift
//  TableProTests
//

import Foundation
@testable import TablePro

extension IndexKeyContext {
    static func testing(_ databaseType: DatabaseType, columns: [String] = []) -> IndexKeyContext {
        IndexKeyContext(
            columnNames: columns,
            dialect: .forType(databaseType),
            grammar: databaseType.lexicalGrammar
        )
    }
}
