import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct MacOnlyConnectionFormTests {
    private func cassandraConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Events",
            type: .cassandra,
            host: "cassandra.example.com",
            port: 9_042,
            username: "reader",
            database: "events",
            additionalFields: ["cassandraLocalDatacenter": "dc1", "cassandraConsistency": "QUORUM"]
        )
    }

    @Test("Renaming a Cassandra connection keeps its type, port and Mac fields")
    func renameKeepsMacOnlyFields() {
        let stored = cassandraConnection()
        let viewModel = ConnectionFormViewModel(editing: stored)

        viewModel.name = "Event Store"
        let saved = viewModel.applyingEdits(to: stored)
        let built = viewModel.buildConnection()

        #expect(saved.name == "Event Store")
        #expect(saved.type == .cassandra)
        #expect(saved.port == 9_042)
        #expect(saved.additionalFields == stored.additionalFields)
        #expect(built.type == .cassandra)
        #expect(built.port == 9_042)
        #expect(built.additionalFields == stored.additionalFields)
    }
}
