import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL statement keywords")
struct MSSQLStatementKeywordsTests {
    @Test("Every word is spelled the way the leading-word scan reports one")
    func wordsAreUppercaseLetters() {
        for word in MSSQLStatementKeywords.leading {
            #expect(word == word.uppercased())
            let lettersOnly = word.allSatisfy { $0.isLetter }
            #expect(lettersOnly)
        }
    }

    @Test("The statements a batch commonly opens with are there", arguments: [
        "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "WITH", "DECLARE", "SET", "EXEC", "EXECUTE", "BEGIN", "IF",
        "WHILE", "PRINT", "RAISERROR", "THROW", "USE", "TRUNCATE", "DROP", "CREATE", "ALTER", "GRANT", "COMMIT",
        "ROLLBACK", "SAVE", "WAITFOR", "DBCC",
    ])
    func commonStatementsAreKeywords(word: String) {
        #expect(MSSQLStatementKeywords.leading.contains(word))
    }

    @Test("A procedure name is not a keyword", arguments: ["SP_HELP", "USP_REPORT", "DBO", "SP_WHO"])
    func procedureNamesAreNotKeywords(word: String) {
        #expect(!MSSQLStatementKeywords.leading.contains(word))
    }
}
