import Foundation
import TableProSQLQuoting

public extension SQLLexicalGrammar {
    // How a literal written for text this grammar reads has to escape, so it ends where it was written.
    var stringEscapes: SQLStringEscapes {
        SQLStringEscapes(
            backslashEscapes: contains(.backslashEscapesInSingleQuotes),
            tripleQuotedStrings: contains(.tripleQuotedStrings)
        )
    }

    func backslashEscapes(in quote: SQLIdentifierQuote) -> Bool {
        switch quote {
        case .doubleQuote: backslashEscapes(inQuote: SqlLexer.doubleQuote)
        case .backtick: backslashEscapes(inQuote: SqlLexer.backtick)
        case .bracket: false
        }
    }
}

public extension SQLLexicalReadings {
    // Escapes for a literal when the session may not have settled whether a backslash escapes: the backslash form
    // doubles both the quote and the backslash, so no reading can end it early. Only GoogleSQL, where a doubled
    // quote opens `'''`, has no such form and takes the execution reading.
    static func stringEscapes(
        databaseTypeId: String,
        declared: SQLLexicalGrammar?,
        session: SQLSessionLexicalFacts?
    ) -> SQLStringEscapes {
        let readings = resolve(databaseTypeId: databaseTypeId, declared: declared, session: session)
        if let session, session.determined.contains(.backslashEscapesInSingleQuotes) {
            return readings.execution.stringEscapes
        }
        guard readings.all.contains(where: { $0.contains(.backslashEscapesInSingleQuotes) }) else { return .standard }
        if readings.all.contains(where: { $0.contains(.tripleQuotedStrings) }) {
            return readings.execution.stringEscapes
        }
        return .backslash
    }
}
