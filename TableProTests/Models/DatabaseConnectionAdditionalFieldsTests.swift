//
//  DatabaseConnectionAdditionalFieldsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("DatabaseConnection.additionalFields")
struct DatabaseConnectionAdditionalFieldsTests {

    // MARK: - Defaults

    @Test("mongoAuthSource defaults to nil")
    func mongoAuthSourceDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .mongodb)
        #expect(conn.mongoAuthSource == nil)
    }

    @Test("mongoReadPreference defaults to nil")
    func mongoReadPreferenceDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .mongodb)
        #expect(conn.mongoReadPreference == nil)
    }

    @Test("mongoWriteConcern defaults to nil")
    func mongoWriteConcernDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .mongodb)
        #expect(conn.mongoWriteConcern == nil)
    }

    @Test("mssqlSchema defaults to nil")
    func mssqlSchemaDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .mssql)
        #expect(conn.mssqlSchema == nil)
    }

    @Test("oracleServiceName defaults to nil")
    func oracleServiceNameDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .oracle)
        #expect(conn.oracleServiceName == nil)
    }

    @Test("redisDatabase defaults to nil")
    func redisDatabaseDefaultsToNil() {
        let conn = TestFixtures.makeConnection(type: .redis)
        #expect(conn.redisDatabase == nil)
    }

    // MARK: - Read/Write via Computed Aliases

    @Test("mongoAuthSource is readable and writable")
    func mongoAuthSourceReadWrite() {
        var conn = TestFixtures.makeConnection(type: .mongodb)
        conn.mongoAuthSource = "admin"
        #expect(conn.mongoAuthSource == "admin")
    }

    @Test("mongoReadPreference is readable and writable")
    func mongoReadPreferenceReadWrite() {
        var conn = TestFixtures.makeConnection(type: .mongodb)
        conn.mongoReadPreference = "secondary"
        #expect(conn.mongoReadPreference == "secondary")
    }

    @Test("mongoWriteConcern is readable and writable")
    func mongoWriteConcernReadWrite() {
        var conn = TestFixtures.makeConnection(type: .mongodb)
        conn.mongoWriteConcern = "majority"
        #expect(conn.mongoWriteConcern == "majority")
    }

    @Test("mssqlSchema is readable and writable")
    func mssqlSchemaReadWrite() {
        var conn = TestFixtures.makeConnection(type: .mssql)
        conn.mssqlSchema = "dbo"
        #expect(conn.mssqlSchema == "dbo")
    }

    @Test("oracleServiceName is readable and writable")
    func oracleServiceNameReadWrite() {
        var conn = TestFixtures.makeConnection(type: .oracle)
        conn.oracleServiceName = "ORCL"
        #expect(conn.oracleServiceName == "ORCL")
    }

    @Test("redisDatabase is readable and writable")
    func redisDatabaseReadWrite() {
        var conn = TestFixtures.makeConnection(type: .redis)
        conn.redisDatabase = 3
        #expect(conn.redisDatabase == 3)
    }

    // MARK: - additionalFields Dict

    @Test("Setting mongoAuthSource writes to additionalFields dict")
    func mongoAuthSourceWritesToDict() {
        var conn = TestFixtures.makeConnection(type: .mongodb)
        conn.mongoAuthSource = "admin"
        #expect(conn.additionalFields["mongoAuthSource"] == "admin")
    }

    @Test("Init with additionalFields dict populates computed aliases")
    func initWithDictPopulatesAliases() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mongodb,
            additionalFields: [
                "mongoAuthSource": "admin",
                "mongoReadPreference": "primary",
                "mongoWriteConcern": "majority"
            ]
        )
        #expect(conn.mongoAuthSource == "admin")
        #expect(conn.mongoReadPreference == "primary")
        #expect(conn.mongoWriteConcern == "majority")
    }

    @Test("Empty string in additionalFields returns nil via nilIfEmpty")
    func emptyStringReturnsNil() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mongodb,
            additionalFields: ["mongoAuthSource": ""]
        )
        #expect(conn.mongoAuthSource == nil)
    }

    @Test("Setting nil via computed alias writes empty string to dict")
    func settingNilWritesEmptyString() {
        var conn = TestFixtures.makeConnection(type: .mongodb)
        conn.mongoAuthSource = "admin"
        conn.mongoAuthSource = nil
        #expect(conn.additionalFields["mongoAuthSource"] == "")
    }

    // MARK: - Init with Named Params

    @Test("init populates mongoAuthSource into additionalFields")
    func initPopulatesMongoAuthSource() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "admin"
        )
        #expect(conn.mongoAuthSource == "admin")
        #expect(conn.additionalFields["mongoAuthSource"] == "admin")
    }

    @Test("init populates mssqlSchema")
    func initPopulatesMssqlSchema() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mssql,
            mssqlSchema: "dbo"
        )
        #expect(conn.mssqlSchema == "dbo")
        #expect(conn.additionalFields["mssqlSchema"] == "dbo")
    }

    @Test("init populates oracleServiceName")
    func initPopulatesOracleServiceName() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .oracle,
            oracleServiceName: "ORCL"
        )
        #expect(conn.oracleServiceName == "ORCL")
        #expect(conn.additionalFields["oracleServiceName"] == "ORCL")
    }

    @Test("init with additionalFields dict overrides named params")
    func initDictOverridesNamedParams() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "fromParam",
            additionalFields: ["mongoAuthSource": "fromDict"]
        )
        #expect(conn.mongoAuthSource == "fromDict")
    }

    // MARK: - Hashable

    @Test("Same fields produce equal connections")
    func sameFieldsAreEqual() {
        let id = UUID()
        let a = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "admin"
        )
        let b = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "admin"
        )
        #expect(a == b)
    }

    @Test("Different additionalFields produce unequal connections")
    func differentAdditionalFieldsAreNotEqual() {
        let id = UUID()
        let a = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "admin"
        )
        let b = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mongodb,
            mongoAuthSource: "other"
        )
        #expect(a != b)
    }

    // MARK: - Codable Round-Trip

    @Test("Codable round-trip preserves mongo additional fields")
    func codableRoundTripMongo() throws {
        let original = DatabaseConnection(
            name: "Mongo",
            type: .mongodb,
            mongoAuthSource: "admin",
            mongoReadPreference: "secondary",
            mongoWriteConcern: "majority"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.mongoAuthSource == "admin")
        #expect(decoded.mongoReadPreference == "secondary")
        #expect(decoded.mongoWriteConcern == "majority")
    }

    @Test("Codable round-trip preserves mssqlSchema")
    func codableRoundTripMssql() throws {
        let original = DatabaseConnection(
            name: "MSSQL",
            type: .mssql,
            mssqlSchema: "dbo"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.mssqlSchema == "dbo")
    }

    @Test("Codable round-trip preserves oracleServiceName")
    func codableRoundTripOracle() throws {
        let original = DatabaseConnection(
            name: "Oracle",
            type: .oracle,
            oracleServiceName: "ORCL"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.oracleServiceName == "ORCL")
    }

    @Test("Codable round-trip preserves nil additional fields")
    func codableRoundTripNils() throws {
        let original = TestFixtures.makeConnection(type: .mongodb)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.mongoAuthSource == nil)
        #expect(decoded.mongoReadPreference == nil)
        #expect(decoded.mongoWriteConcern == nil)
        #expect(decoded.mssqlSchema == nil)
        #expect(decoded.oracleServiceName == nil)
        #expect(decoded.redisDatabase == nil)
    }
}
