import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct MacOnlyConnectionFormTests {
    private func mongoConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Events",
            type: .mongodb,
            host: "mongo.example.com",
            port: 27_017,
            username: "reader",
            database: "events",
            additionalFields: ["mongoAuthSource": "admin", "mongoReplicaSet": "rs0"]
        )
    }

    @Test("Renaming a MongoDB connection keeps its type, port and Mac fields")
    func renameKeepsMacOnlyFields() {
        let stored = mongoConnection()
        let viewModel = ConnectionFormViewModel(editing: stored)

        viewModel.name = "Event Store"
        let saved = viewModel.applyingEdits(to: stored)
        let built = viewModel.buildConnection()

        #expect(saved.name == "Event Store")
        #expect(saved.type == .mongodb)
        #expect(saved.port == 27_017)
        #expect(saved.additionalFields == stored.additionalFields)
        #expect(built.type == .mongodb)
        #expect(built.port == 27_017)
        #expect(built.additionalFields == stored.additionalFields)
    }
}
