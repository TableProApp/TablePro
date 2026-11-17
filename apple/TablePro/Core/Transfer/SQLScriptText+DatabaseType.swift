import Foundation
import TableProSQLGrammar

// The grammar comes from the registry, so a plugin engine TablePro does not curate lexes the way its plugin declares.
extension SQLScriptText {
    init(databaseType: DatabaseType) {
        self.init(databaseType: databaseType, grammar: databaseType.lexicalGrammar)
    }

    init(databaseType: DatabaseType, grammar: SQLLexicalGrammar) {
        self.init(databaseTypeId: databaseType.rawValue, grammar: grammar, readings: databaseType.lexicalReadings)
    }
}
