import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

struct IOSDriverFactoryCatalogTests {
    @Test("Wire-protocol SQL servers get a catalog connection; file, HTTP and Redis engines keep one connection")
    func whichEnginesOpenOne() {
        let factory = IOSDriverFactory()
        let opens: [DatabaseType] = [.mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .mssql, .oracle]
        for type in opens {
            #expect(factory.opensCatalogConnections(for: DatabaseConnection(name: "c", type: type)))
        }
        // D1 holds no session state a catalog read could disturb, and a second driver costs requests on every open.
        for type in [DatabaseType.sqlite, .duckdb, .redis, .clickhouse, .cloudflareD1] {
            #expect(!factory.opensCatalogConnections(for: DatabaseConnection(name: "c", type: type)))
        }
    }

    @Test("A MySQL catalog connection autocommits, and a SQL Server one stops waiting on locks")
    func mysqlCatalogAutocommits() async throws {
        let factory = IOSDriverFactory()
        let mysql = MockDatabaseDriver()
        let sqlServer = MockDatabaseDriver()
        let postgres = MockDatabaseDriver()

        try await factory.prepareCatalogDriver(mysql, for: DatabaseConnection(name: "c", type: .mariadb))
        try await factory.prepareCatalogDriver(sqlServer, for: DatabaseConnection(name: "c", type: .mssql))
        try await factory.prepareCatalogDriver(postgres, for: DatabaseConnection(name: "c", type: .postgresql))

        #expect(mysql.executedQueries == ["SET autocommit = 1"])
        #expect(sqlServer.executedQueries == ["SET LOCK_TIMEOUT 2000"])
        #expect(postgres.executedQueries.isEmpty)
    }
}
