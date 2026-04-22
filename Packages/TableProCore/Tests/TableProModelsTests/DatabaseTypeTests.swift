import Testing
import Foundation
@testable import TableProModels

@Suite("DatabaseType Tests")
struct DatabaseTypeTests {
    @Test("Static constants have correct raw values matching macOS")
    func staticConstants() {
        #expect(DatabaseType.mysql.rawValue == "MySQL")
        #expect(DatabaseType.mariadb.rawValue == "MariaDB")
        #expect(DatabaseType.postgresql.rawValue == "PostgreSQL")
        #expect(DatabaseType.sqlite.rawValue == "SQLite")
        #expect(DatabaseType.redis.rawValue == "Redis")
        #expect(DatabaseType.mongodb.rawValue == "MongoDB")
        #expect(DatabaseType.mssql.rawValue == "SQL Server")
        #expect(DatabaseType.cloudflareD1.rawValue == "Cloudflare D1")
        #expect(DatabaseType.bigquery.rawValue == "BigQuery")
    }

    @Test("pluginTypeId maps multi-type databases")
    func pluginTypeIdMapping() {
        #expect(DatabaseType.mysql.pluginTypeId == "MySQL")
        #expect(DatabaseType.mariadb.pluginTypeId == "MySQL")
        #expect(DatabaseType.postgresql.pluginTypeId == "PostgreSQL")
        #expect(DatabaseType.redshift.pluginTypeId == "PostgreSQL")
        #expect(DatabaseType.sqlite.pluginTypeId == "SQLite")
    }

    @Test("Unknown types pass through pluginTypeId")
    func unknownTypePassthrough() {
        let custom = DatabaseType(rawValue: "custom_db")
        #expect(custom.pluginTypeId == "custom_db")
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        let original = DatabaseType.postgresql
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: data)
        #expect(decoded == original)
    }

    @Test("Unknown type Codable round-trip")
    func unknownCodableRoundTrip() throws {
        let original = DatabaseType(rawValue: "future_db")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rawValue == "future_db")
    }

    @Test("allKnownTypes contains all expected types")
    func allKnownTypesComplete() {
        #expect(DatabaseType.allKnownTypes.count == 17)
        #expect(DatabaseType.allKnownTypes.contains(.mysql))
        #expect(DatabaseType.allKnownTypes.contains(.bigquery))
        #expect(DatabaseType.allKnownTypes.contains(.libsql))
    }

    @Test("Hashable conformance")
    func hashableConformance() {
        var set: Set<DatabaseType> = [.mysql, .postgresql, .mysql]
        #expect(set.count == 2)
        set.insert(DatabaseType(rawValue: "MySQL"))
        #expect(set.count == 2)
    }
}
