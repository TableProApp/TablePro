import Foundation
@testable import TablePro
import Testing

// The editor closes `[` and `"` as they are typed, so the caret sits before the close and the bare name goes between.
struct SQLCompletionServiceTokenStartTests {
    @MainActor
    @Test(
        "A closed pair starts the token after its opening quote",
        arguments: [
            (DatabaseType.mssql, "SELECT * FROM [ord]", "SELECT * FROM [orders]"),
            (DatabaseType.postgresql, "SELECT * FROM \"ord\"", "SELECT * FROM \"orders\"")
        ]
    )
    func closedPairStartsAfterTheQuote(databaseType: DatabaseType, typed: String, accepted: String) {
        let service = SQLCompletionService(schemaProvider: nil, databaseType: databaseType)
        let text = typed as NSString

        let start = service.tokenStart(in: text, endingAt: 18)

        #expect(start == 15)
        #expect(text.replacingCharacters(in: NSRange(location: start, length: 18 - start), with: "orders") == accepted)
    }

    @MainActor
    @Test("An open bracket is part of the token on SQL Server")
    func openBracketIsPartOfTheToken() {
        let service = SQLCompletionService(schemaProvider: nil, databaseType: .mssql)

        #expect(service.tokenStart(in: "SELECT * FROM [ord" as NSString, endingAt: 18) == 14)
    }
}
