import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct OpenTransactionWarningTests {
    private let oneCredentials = String(
        localized: "Are you sure you want to delete this connection? Saved credentials will be permanently removed."
    )
    private let manyCredentials = String(localized: "Saved credentials for these connections will be permanently removed.")

    @Test("Deleting connections that hold no transaction asks only about their credentials")
    func deletionWithoutTransactions() {
        #expect(OpenTransactionWarning.deletion(deletingCount: 1, holdingTransactions: []) == oneCredentials)
        #expect(OpenTransactionWarning.deletion(deletingCount: 3, holdingTransactions: []) == manyCredentials)
    }

    @Test("Deleting a connection with an open transaction says it is rolled back, before the credentials")
    func deletionNamesOneTransaction() {
        let transaction = String(
            format: String(
                localized: "“%@” has an open transaction. Deleting the connection rolls it back and discards its uncommitted changes."
            ),
            "Prod"
        )

        #expect(OpenTransactionWarning.deletion(deletingCount: 1, holdingTransactions: ["Prod"]) == "\(transaction) \(oneCredentials)")
        #expect(OpenTransactionWarning.deletion(deletingCount: 2, holdingTransactions: ["Prod"]) == "\(transaction) \(manyCredentials)")
    }

    @Test("Deleting several connections with open transactions names each one")
    func deletionNamesEveryTransaction() {
        let english = Locale(identifier: "en_US")
        let message = OpenTransactionWarning.deletion(
            deletingCount: 3,
            holdingTransactions: ["Prod", "Staging"],
            locale: english
        )
        let transactions = String(
            format: String(
                localized: "These connections have open transactions: %@. Deleting them rolls the transactions back and discards their uncommitted changes."
            ),
            "“Prod” and “Staging”"
        )

        #expect(message == "\(transactions) \(manyCredentials)")
    }

    @Test("Truncate and Drop on MySQL-family engines and Oracle say they commit the open transaction")
    func ddlCommitNote() {
        let message = "All data will be deleted."
        let commits = String(localized: "This also commits the open transaction, keeping its uncommitted changes.")

        for type in [DatabaseType.mysql, .mariadb, .tidb, .oceanbase, .oracle] {
            #expect(
                OpenTransactionWarning.ddlConfirmation(message, type: type, holdsTransaction: true) == "\(message) \(commits)",
                "\(type.rawValue)"
            )
            #expect(OpenTransactionWarning.ddlConfirmation(message, type: type, holdsTransaction: false) == message)
        }
        for type in [DatabaseType.postgresql, .sqlite, .mssql, .duckdb] {
            #expect(
                OpenTransactionWarning.ddlConfirmation(message, type: type, holdsTransaction: true) == message,
                "\(type.rawValue)"
            )
        }
    }
}
