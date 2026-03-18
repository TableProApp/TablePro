//
//  ConnectionStorageAdditionalFieldsTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("ConnectionStorage Additional Fields", .serialized)
struct ConnectionStorageAdditionalFieldsTests {
    private let storage = ConnectionStorage.shared

    @Test("round-trip preserves MongoDB-specific fields")
    func roundTripMongoFields() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test Mongo",
            host: "localhost",
            port: 27_017,
            type: .mongodb,
            mongoAuthSource: "admin",
            mongoReadPreference: "secondary",
            mongoWriteConcern: "majority"
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.mongoAuthSource == "admin")
        #expect(loaded?.mongoReadPreference == "secondary")
        #expect(loaded?.mongoWriteConcern == "majority")
    }

    @Test("round-trip preserves MSSQL schema")
    func roundTripMssqlSchema() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test MSSQL",
            host: "localhost",
            port: 1_433,
            type: .mssql,
            mssqlSchema: "custom_schema"
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.mssqlSchema == "custom_schema")
    }

    @Test("round-trip preserves Oracle service name")
    func roundTripOracleServiceName() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test Oracle",
            host: "localhost",
            port: 1_521,
            type: .oracle,
            oracleServiceName: "ORCL"
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.oracleServiceName == "ORCL")
    }

    @Test("round-trip preserves Redis database index")
    func roundTripRedisDatabase() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test Redis",
            host: "localhost",
            port: 6_379,
            type: .redis,
            redisDatabase: 5
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.redisDatabase == 5)
    }

    @Test("round-trip preserves startup commands")
    func roundTripStartupCommands() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test Startup",
            host: "localhost",
            port: 3_306,
            type: .mysql,
            startupCommands: "SET NAMES utf8mb4;\nSET sql_mode = 'STRICT_TRANS_TABLES';"
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.startupCommands == "SET NAMES utf8mb4;\nSET sql_mode = 'STRICT_TRANS_TABLES';")
    }

    @Test("nil optional fields don't break loading")
    func nilFieldsLoadCorrectly() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test Nil Fields",
            host: "localhost",
            port: 3_306,
            type: .mysql
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded != nil)
        #expect(loaded?.mongoAuthSource == nil)
        #expect(loaded?.mongoReadPreference == nil)
        #expect(loaded?.mongoWriteConcern == nil)
        #expect(loaded?.redisDatabase == nil)
        #expect(loaded?.mssqlSchema == nil)
        #expect(loaded?.oracleServiceName == nil)
        #expect(loaded?.startupCommands == nil)
    }

    @Test("save and reload clears cache and round-trips correctly")
    func saveAndReloadClearsCache() {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }

        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Cache Test",
            host: "localhost",
            port: 27_017,
            type: .mongodb,
            mongoAuthSource: "testdb"
        )

        storage.saveConnections([connection])

        // Force cache invalidation by saving again with the same data
        let data = UserDefaults.standard.data(forKey: "com.TablePro.connections")
        #expect(data != nil)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded[0].mongoAuthSource == "testdb")
    }

    @Test("multiple database-specific fields coexist on different connections")
    func multipleConnectionsWithDifferentFields() {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }

        let mongoId = UUID()
        let mongo = DatabaseConnection(
            id: mongoId,
            name: "Mongo",
            host: "localhost",
            port: 27_017,
            type: .mongodb,
            mongoAuthSource: "admin"
        )

        let redisId = UUID()
        let redis = DatabaseConnection(
            id: redisId,
            name: "Redis",
            host: "localhost",
            port: 6_379,
            type: .redis,
            redisDatabase: 3
        )

        let mssqlId = UUID()
        let mssql = DatabaseConnection(
            id: mssqlId,
            name: "MSSQL",
            host: "localhost",
            port: 1_433,
            type: .mssql,
            mssqlSchema: "dbo"
        )

        storage.saveConnections([mongo, redis, mssql])

        let loaded = storage.loadConnections()
        #expect(loaded.count == 3)

        let loadedMongo = loaded.first { $0.id == mongoId }
        let loadedRedis = loaded.first { $0.id == redisId }
        let loadedMssql = loaded.first { $0.id == mssqlId }

        #expect(loadedMongo?.mongoAuthSource == "admin")
        #expect(loadedRedis?.redisDatabase == 3)
        #expect(loadedMssql?.mssqlSchema == "dbo")
    }
}
