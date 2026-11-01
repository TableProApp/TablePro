import Foundation
import TableProSQLGrammar

enum DamengGrammar {
    // The reading the app runs a Dameng session's text with: DM8's measured grammar plus the BACKSLASH_ESCAPE mode the
    // driver detects at connect and reports as its session state.
    static func execution(backslashEscapes: Bool) -> SQLLexicalGrammar {
        let session = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: backslashEscapes ? .backslashEscapesInSingleQuotes : []
        )
        return SQLLexicalReadings.resolve(databaseTypeId: "Dameng", declared: nil, session: session).execution
    }
}
