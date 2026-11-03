//
//  ImportCancelledTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ImportCancelledTextTests {
    @Test("A rolled back import says so")
    func rolledBack() {
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 12, transaction: .rolledBack)
                == "12 statements had already run and were rolled back."
        )
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 1, transaction: .rolledBack)
                == "1 statement had already run and was rolled back."
        )
    }

    @Test("An import the database committed part way says some of it was kept, and why")
    func committedBeforeRollback() {
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 848, transaction: .committedBeforeRollback)
                == "848 statements had already run. Some were kept, because a statement in the file, such as "
                + "COMMIT, CREATE, ALTER or DROP, committed the import's transaction as it ran."
        )
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 1, transaction: .committedBeforeRollback)
                == "1 statement had already run and was kept, because a statement in the file, such as COMMIT, "
                + "CREATE, ALTER or DROP, committed the import's transaction as it ran."
        )
    }

    @Test("An import with no known transaction outcome makes no durability claim")
    func untracked() {
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 3, transaction: .untracked)
                == "Anything already imported may stay."
        )
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 1, transaction: .committed)
                == "1 statement had already run and stays committed."
        )
    }

    @Test("A transaction the server or the file ended makes no claim about rolled back or kept")
    func endedOutsideTheImport() {
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 5, transaction: .endedByServer)
                == "Anything already imported may stay."
        )
        #expect(
            TransferResultAlert.importCancelledText(executedStatements: 5, transaction: .endedByFile)
                == "Anything already imported may stay."
        )
    }
}
