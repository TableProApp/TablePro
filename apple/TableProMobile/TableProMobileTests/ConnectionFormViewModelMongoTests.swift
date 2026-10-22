import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ConnectionFormViewModelMongoTests {
    private func macConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Events",
            type: .mongodb,
            host: "db1.internal",
            port: 27_017,
            username: "reader",
            database: "events",
            additionalFields: [
                "mongoHosts": "db1.internal:27017,db2.internal:27017",
                "mongoAuthSource": "admin",
                "mongoReplicaSet": "rs0",
                "mongoReadPreference": "secondaryPreferred"
            ]
        )
    }

    @Test("A Mac connection opens with its seed list, and a rename writes no other field")
    func renameKeepsTheMacFields() {
        let stored = macConnection()
        let viewModel = ConnectionFormViewModel(editing: stored)

        viewModel.name = "Event Store"
        let saved = viewModel.applyingEdits(to: stored)

        #expect(viewModel.mongoHosts == "db1.internal:27017,db2.internal:27017")
        #expect(viewModel.mongoAuthSource == "admin")
        #expect(viewModel.mongoReplicaSet == "rs0")
        #expect(saved.name == "Event Store")
        #expect(saved.additionalFields == stored.additionalFields)
        #expect(saved.host == "db1.internal")
    }

    @Test("Hosts is what the driver dials, and Host and Port follow its first entry")
    func hostsDecideTheDialedServer() {
        let stored = macConnection()
        let viewModel = ConnectionFormViewModel(editing: stored)

        viewModel.mongoHosts = "db3.internal:27018, db1.internal"
        let saved = viewModel.applyingEdits(to: stored)

        #expect(saved.additionalFields["mongoHosts"] == "db3.internal:27018,db1.internal:27017")
        #expect(saved.host == "db3.internal")
        #expect(saved.port == 27_018)
        #expect(saved.additionalFields["mongoReadPreference"] == "secondaryPreferred")
    }

    @Test("A connection with no seed list opens with Host and Port as its one entry")
    func hostSeedsTheList() {
        let viewModel = ConnectionFormViewModel(
            editing: DatabaseConnection(type: .mongodb, host: "mongo.example.com", port: 27_018)
        )

        #expect(viewModel.mongoHosts == "mongo.example.com:27018")
    }

    @Test("A new MongoDB connection starts on port 27017 and saves the Mac's field keys")
    func newConnectionWritesTheMacKeys() {
        let viewModel = ConnectionFormViewModel()
        viewModel.type = .mongodb
        viewModel.mongoAuthSource = "admin"
        viewModel.mongoAuthMechanism = "SCRAM-SHA-256"
        viewModel.mongoReplicaSet = "rs0"
        viewModel.mongoUsesSRV = true

        let built = viewModel.buildConnection()

        #expect(viewModel.port == "27017")
        #expect(built.host == "127.0.0.1")
        #expect(built.port == 27_017)
        #expect(built.additionalFields["mongoHosts"] == "127.0.0.1:27017")
        #expect(built.additionalFields["mongoAuthSource"] == "admin")
        #expect(built.additionalFields["mongoAuthMechanism"] == "SCRAM-SHA-256")
        #expect(built.additionalFields["mongoReplicaSet"] == "rs0")
        #expect(built.additionalFields["mongoUseSrv"] == "true")
    }

    @Test("An entry that is not a host or host:port, or no entry, keeps Save off")
    func invalidHostsBlockSave() {
        let viewModel = ConnectionFormViewModel(editing: macConnection())

        viewModel.mongoHosts = "db1.internal:27017,db2/x"
        #expect(viewModel.mongoHostsIssue != nil)
        #expect(!viewModel.canSave)

        viewModel.mongoHosts = " , "
        #expect(!viewModel.canSave)

        viewModel.mongoHosts = "db1.internal"
        #expect(viewModel.canSave)
    }

    @Test("A verify mode with no CA certificate says MongoDB here needs one")
    func verifyModeNeedsACA() {
        let viewModel = ConnectionFormViewModel()
        viewModel.type = .mongodb
        viewModel.sslMode = .verifyFull

        #expect(viewModel.sslModeNote == MongoDBDialPlan.verifyNeedsCAMessage)

        viewModel.sslMode = .preferred
        #expect(viewModel.sslModeNote == ConnectionFormViewModel.mongoPreferredForcesTLSMessage)

        viewModel.sslMode = .require
        #expect(viewModel.sslModeNote == nil)
    }
}
