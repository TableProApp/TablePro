import TableProSQLGrammar

extension SQLLexicalGrammar {
    static func engine(_ databaseTypeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: databaseTypeId, declared: nil, session: nil).execution
    }
}
