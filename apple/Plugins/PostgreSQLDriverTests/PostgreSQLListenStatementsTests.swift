import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLListenStatementsTests {
    @Test("Each channel is LISTENed as a quoted identifier, so case and quotes survive")
    func listenQuotesIdentifiers() {
        #expect(PostgreSQLListenStatements.listen(["Orders", "a\"b"]) == [
            "LISTEN \"Orders\"",
            "LISTEN \"a\"\"b\"",
        ])
    }

    @Test("NOTIFY goes through pg_notify with bound parameters, never a spliced payload")
    func notifyIsParameterized() {
        #expect(PostgreSQLListenStatements.notifyStatement == "SELECT pg_catalog.pg_notify($1, $2)")
    }
}
