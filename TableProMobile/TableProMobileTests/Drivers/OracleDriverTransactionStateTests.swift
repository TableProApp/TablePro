import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

/// Oracle commits nothing on its own, so a row edit only reaches the server for good when the driver either sends it
/// with the commit flag or wraps it in a transaction it then commits. These pin what the driver reports to the write
/// path, which is what decides between the two.
@Suite("Oracle transaction state on iOS")
struct OracleDriverTransactionStateTests {
    private func makeDriver() -> OracleDriver {
        OracleDriver(
            connection: DatabaseConnection(type: .oracle, host: "127.0.0.1", port: 1_521, username: "app"),
            password: nil
        )
    }

    @Test("A session with nothing open is idle, so a row edit gets a transaction the app commits")
    func idleSessionOpensItsOwnTransaction() async {
        let driver = makeDriver()
        let state = await driver.sessionTransactionState()
        #expect(state == .idle)
        #expect(WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: state, statementCount: 1))
    }

    @Test("An opened transaction is reported, so a row edit joins it and leaves the commit to its owner")
    func openTransactionIsJoined() async throws {
        let driver = makeDriver()
        try await driver.beginTransaction()
        let state = await driver.sessionTransactionState()
        #expect(state == .explicitTransaction)
        #expect(!WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: state, statementCount: 1))
    }
}
