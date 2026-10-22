import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProQuery
import Testing

struct MongoDBOnIOSTests {
    private func driver(database: String = "app") -> MongoDBBackedDriver {
        let config = DriverConnectionConfig(
            host: "db.example.com", port: 27_017, username: "u", password: "p", database: database
        )
        return MongoDBBackedDriver(mongo: MongoDBPluginDriver(config: config), dialedHosts: [])
    }

    private func request(
        filters: [TableFilter] = [],
        logicMode: FilterLogicMode = .and,
        search: String? = nil,
        searchColumns: [String] = [],
        sort: SortState = SortState()
    ) -> TableReadRequest {
        TableReadRequest(
            table: "users",
            schema: nil,
            filters: filters,
            logicMode: logicMode,
            searchText: search,
            searchColumns: searchColumns,
            sortState: sort
        )
    }

    private func connection(fields: [String: String], host: String = "db1.internal") -> DatabaseConnection {
        DatabaseConnection(type: .mongodb, host: host, port: 27_017, database: "app", additionalFields: fields)
    }

    private func caFile() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mongo-ca-\(UUID().uuidString).pem")
        try Data("-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n".utf8).write(to: url)
        return url.path
    }

    @Test("The factory opens MongoDB through the plugin driver, matching documents on _id")
    func factoryOpensMongoDB() throws {
        let connection = DatabaseConnection(type: .mongodb, host: "db.example.com", port: 27_017, database: "app")

        let opened = try IOSDriverFactory(materializer: CertificateMaterializer(store: InMemoryCertificateStore()))
            .createDriver(for: connection, password: "p")

        let mongo = try #require(opened as? MongoDBBackedDriver)
        #expect(mongo.rowIdentity == .keyColumns)
        #expect(mongo.supportsTransactions == false)
        #expect(mongo.currentDatabase == "app")
    }

    @Test("With no database named, the session has none to report until the plugin opens one")
    func unnamedDatabaseIsNotReported() {
        #expect(driver(database: "").currentDatabase == nil)
    }

    @Test("A page carries the filters and the search, both, with the sort and the page window")
    func pageQueryCombinesFiltersAndSearch() {
        let query = driver().pageQuery(
            request(
                filters: [TableFilter(columnName: "name", filterOperator: .equal, value: "ann")],
                search: "x",
                searchColumns: ["name", "email"],
                sort: SortState(columns: [SortColumn(name: "name", ascending: true)])
            ),
            limit: 50,
            offset: 100
        )

        #expect(query == #"db.users.find({"$and": [{"name": "ann"}, {"$or": [{"name": {"$regex": "x", "$options": "i"}}, {"email": {"$regex": "x", "$options": "i"}}]}]}).sort({"name": 1}).skip(100).limit(50)"#)
    }

    @Test("A page with nothing to match reads the whole collection")
    func plainPage() {
        #expect(driver().pageQuery(request(), limit: 25, offset: 0) == "db.users.find({}).limit(25)")
    }

    @Test("A filter the plugin cannot express matches nothing rather than being left out")
    func unexpressibleFilterMatchesNothing() {
        let query = driver().pageQuery(
            request(filters: [TableFilter(columnName: "name", filterOperator: .like, value: "a%")]),
            limit: 25,
            offset: 0
        )

        #expect(query == "db.users.find(\(MongoDBQueryBuilder.impossibleFilter)).limit(25)")
    }

    @Test("A field named like the raw-filter column, or starting with $, never has its value read as a filter document")
    func unfilterableFieldsMatchNothing() {
        let payload = #"{"$where": "sleep(100) || true"}"#
        let filtered = driver().pageQuery(
            request(filters: [TableFilter(columnName: MongoDBQueryBuilder.rawFilterColumn, filterOperator: .equal, value: payload)]),
            limit: 5,
            offset: 0
        )
        let searched = driver().pageQuery(
            request(search: payload, searchColumns: [MongoDBQueryBuilder.rawFilterColumn, "$price"]),
            limit: 5,
            offset: 0
        )

        #expect(filtered == "db.users.find(\(MongoDBQueryBuilder.impossibleFilter)).limit(5)")
        #expect(searched == "db.users.find(\(MongoDBQueryBuilder.impossibleFilter)).limit(5)")
    }

    @Test("The filter sheet offers every operator the plugin builds, and no LIKE pattern")
    func operatorsAreThePluginOnes() {
        let operators = driver().filterOperators

        #expect(!operators.contains(.like))
        #expect(!operators.contains(.notLike))
        #expect(operators.contains(.contains))
        #expect(operators.contains(.between))
        #expect(operators.allSatisfy { $0.pluginOperator != nil })
    }

    @Test("A BETWEEN filter carries its upper bound apart, so a comma inside a bound stays in it")
    func betweenKeepsItsBounds() throws {
        let filter = TableFilter(columnName: "age", filterOperator: .between, value: "1", secondValue: "9")
        let plugin = try #require(filter.pluginFilter)

        #expect(plugin.op == "BETWEEN")
        #expect(plugin.value == "1,9")
        #expect(plugin.secondValue == "9")
    }

    @Test("A browse page runs as a proven read, so the shell refuses any write it would make")
    func browseRunsReadOnly() async throws {
        let plugin = StubPluginDriver()
        plugin.answersBoundedReads = false
        let driver = PluginBackedDriver(
            plugin: plugin,
            dialedHosts: [],
            rowIdentity: .keyColumns,
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .mongodb) },
            provesReads: true
        )

        for try await _ in driver.executeStreaming(query: "db.users.find({}).limit(5)", options: StreamOptions(maxRows: 5)) {}
        for try await _ in driver.executeStreaming(query: "db.users.deleteMany({})", options: StreamOptions(maxRows: 5)) {}

        let readOnly = plugin.contexts.map { $0.readOnly }
        #expect(readOnly == [true, false])
    }

    @Test("A driver whose read test is a guess never marks a statement read-only")
    func guessedReadsStayWritable() async throws {
        let plugin = StubPluginDriver()
        plugin.answersBoundedReads = false
        let driver = PluginBackedDriver(plugin: plugin, dialedHosts: [], rowIdentity: .everyColumn, readsOnly: { _ in true })

        _ = try await driver.execute(query: "SELECT 1")

        let readOnly = plugin.contexts.map { $0.readOnly }
        #expect(readOnly == [false])
    }

    @Test("Behind a tunnel the seed list goes and the driver talks to the forward alone")
    func tunnelDropsTheSeedList() throws {
        let fields = try MongoDBDialPlan.additionalFields(
            of: connection(fields: ["mongoHosts": "db1.internal:27017,db2.internal:27017", "mongoReplicaSet": "rs0"]),
            preTunnelHost: "db1.internal"
        )

        #expect(fields["mongoHosts"] == nil)
        #expect(fields["mongoParam_directConnection"] == "true")
        #expect(fields["mongoReplicaSet"] == "rs0")
    }

    @Test("Behind a tunnel an SRV name is refused: it resolves to servers the driver would dial around the tunnel")
    func tunnelRefusesSRV() {
        #expect(throws: DatabaseError.self) {
            try MongoDBDialPlan.additionalFields(
                of: connection(fields: [:], host: "127.0.0.1"),
                preTunnelHost: "cluster0.ab1cd.mongodb.net"
            )
        }
        #expect(throws: DatabaseError.self) {
            try MongoDBDialPlan.additionalFields(of: connection(fields: ["mongoUseSrv": "true"]), preTunnelHost: "db1.internal")
        }
    }

    @Test("Without a tunnel the fields reach the plugin as stored")
    func directKeepsTheFields() throws {
        let stored = ["mongoHosts": "db1.internal:27017,db2.internal:27018"]

        #expect(try MongoDBDialPlan.additionalFields(of: connection(fields: stored), preTunnelHost: nil) == stored)
    }

    @Test("Every seed host is a host the driver dials, so each gets the local network check")
    func seedHostsAreDialed() {
        #expect(MongoDBDialPlan.seedHosts(of: connection(fields: ["mongoHosts": "db1.internal:27017,[::1]:27018"]))
            == ["db1.internal", "::1"])
        #expect(MongoDBDialPlan.seedHosts(of: connection(fields: [:])) == ["db1.internal"])
    }

    @Test("A verify mode without a CA certificate is refused: OpenSSL here has no trust store")
    func verifyNeedsACA() {
        for mode in [TableProModels.SSLConfiguration.SSLMode.verifyCa, .verifyFull] {
            #expect(throws: DatabaseError.self) {
                try MongoDBDialPlan.ssl(DriverSSLConfiguration(mode: mode), tunneled: false)
            }
        }
        #expect((try? MongoDBDialPlan.ssl(DriverSSLConfiguration(mode: .require), tunneled: false))?.mode == .require)
    }

    @Test("Behind a tunnel Verify Identity still checks the chain against the CA, only not the loopback name")
    func tunnelKeepsTheChainCheck() throws {
        let ca = try caFile()
        defer { try? FileManager.default.removeItem(atPath: ca) }

        let tunneled = try MongoDBDialPlan.ssl(DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: ca), tunneled: true)
        let direct = try MongoDBDialPlan.ssl(DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: ca), tunneled: false)

        #expect(tunneled.mode == .verifyCa)
        #expect(tunneled.caCertificatePath == ca)
        #expect(direct.mode == .verifyFull)
    }

    @Test("A statement is a read only when the shell grammar proves it")
    func readsAreProven() {
        #expect(!SQLWriteClassifier.isWriteQuery("db.users.find({status: \"open\"})", databaseType: .mongodb))
        #expect(SQLWriteClassifier.isWriteQuery("db.users.deleteMany({})", databaseType: .mongodb))
        #expect(SQLWriteClassifier.isWriteQuery("db.users.find(db.users[(\"delete\" + \"Many\")]({}))", databaseType: .mongodb))
    }

    @Test("MongoDB lists like a SQL engine but speaks no SQL, on its own port")
    func typeLists() {
        #expect(DatabaseType.mobileSupportedTypes.contains(.mongodb))
        #expect(DatabaseType.mongodb.defaultPort == "27017")
        #expect(DatabaseType.mongodb.speaksSQL == false)
        #expect(ExportFormat.offered(for: .mongodb) == [.json, .csv])
        #expect(ExportFormat.offered(for: .postgresql) == ExportFormat.allCases)
    }
}
