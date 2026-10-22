import Foundation
@testable import TableProMobile
import TableProModels
import Testing
import UIKit

struct TransactionIndicatorContentTests {
    @Test("An open transaction shows the database it runs in, and VoiceOver also names the connection")
    func openNamesDatabaseAndConnection() {
        let content = TransactionIndicatorContent(
            isAborted: false,
            connectionName: "Prod",
            activeDatabase: "orders",
            switchesDatabases: true,
            safeModeLevel: .off
        )

        #expect(content.title == String(localized: "Transaction Open"))
        #expect(content.subtitle == "orders")
        #expect(content.accessibilityLabel == String(
            format: String(localized: "Transaction open on %1$@, %2$@"),
            "orders",
            "Prod"
        ))
        #expect(content.symbolName == TransactionIndicatorContent.openSymbolName)
        #expect(content.commit == .runs)
    }

    @Test("The Sample has no database to name, so the bar and VoiceOver name the connection once")
    func sampleNamesTheConnectionOnce() {
        let sample = SampleDatabaseInstaller.connectionName
        // A SQLite session can restore a stale lastDB, which names nothing on the server.
        let content = TransactionIndicatorContent(
            isAborted: false,
            connectionName: sample,
            activeDatabase: SampleDatabaseInstaller.fileName,
            switchesDatabases: false,
            safeModeLevel: .off
        )

        #expect(content.subtitle == sample)
        #expect(content.accessibilityLabel == String(format: String(localized: "Transaction open on %@"), sample))
        #expect(!content.accessibilityLabel.contains(SampleDatabaseInstaller.fileName))
    }

    @Test("An engine that switches databases but has not named one yet falls back to the connection")
    func emptyDatabaseFallsBackToConnection() {
        let content = TransactionIndicatorContent(
            isAborted: false,
            connectionName: "Prod",
            activeDatabase: "",
            switchesDatabases: true,
            safeModeLevel: .off
        )

        #expect(content.subtitle == "Prod")
        #expect(content.accessibilityLabel == String(format: String(localized: "Transaction open on %@"), "Prod"))
    }

    @Test("A failed transaction says to roll it back and offers no Commit")
    func abortedOffersOnlyRollBack() {
        let content = TransactionIndicatorContent(
            isAborted: true,
            connectionName: "Prod",
            activeDatabase: "orders",
            switchesDatabases: true,
            safeModeLevel: .off
        )

        #expect(content.title == String(localized: "Transaction Failed"))
        #expect(content.subtitle == String(localized: "Roll it back to continue."))
        #expect(content.accessibilityLabel == String(
            format: String(localized: "Transaction failed on %1$@, %2$@. Roll it back to continue."),
            "orders",
            "Prod"
        ))
        #expect(content.symbolName == TransactionIndicatorContent.abortedSymbolName)
        #expect(content.commit == .hidden)
    }

    @Test("A failed transaction with no database names the connection once")
    func abortedWithoutDatabase() {
        let content = TransactionIndicatorContent(
            isAborted: true,
            connectionName: "Local",
            activeDatabase: "",
            switchesDatabases: false,
            safeModeLevel: .off
        )

        #expect(content.accessibilityLabel == String(
            format: String(localized: "Transaction failed on %@. Roll it back to continue."),
            "Local"
        ))
    }

    @Test(
        "Commit follows the Safe Mode write permission",
        arguments: zip(
            [SafeModeLevel.off, .confirmWrites, .readOnly],
            [TransactionIndicatorContent.CommitOffer.runs, .asksFirst, .hidden]
        )
    )
    func commitFollowsSafeMode(level: SafeModeLevel, offer: TransactionIndicatorContent.CommitOffer) {
        let content = TransactionIndicatorContent(
            isAborted: false,
            connectionName: "Prod",
            activeDatabase: "orders",
            switchesDatabases: true,
            safeModeLevel: level
        )

        #expect(content.commit == offer)
    }

    @Test("Only a PostgreSQL or Redshift database switch dials a new session")
    func databaseSwitchEndsSession() {
        #expect(TransactionIndicatorContent.databaseSwitchEndsSession(for: .postgresql))
        #expect(TransactionIndicatorContent.databaseSwitchEndsSession(for: .redshift))
        #expect(!TransactionIndicatorContent.databaseSwitchEndsSession(for: .mysql))
        #expect(!TransactionIndicatorContent.databaseSwitchEndsSession(for: .mssql))
        #expect(!TransactionIndicatorContent.databaseSwitchEndsSession(for: .sqlite))
    }

    @MainActor
    @Test("Every symbol the bar and the connection list draw exists on this system")
    func symbolsExist() {
        let names = [
            TransactionIndicatorContent.openSymbolName,
            TransactionIndicatorContent.abortedSymbolName,
            TransactionIndicatorContent.commitSymbolName,
            TransactionIndicatorContent.rollBackSymbolName,
        ]

        for name in names {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
    }
}
