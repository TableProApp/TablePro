//
//  DatabaseConnectionAdditionalFieldsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DatabaseConnectionAdditionalFieldsTests {
    // MARK: - Read/Write via Computed Aliases

    @Test("redisDatabase is readable and writable")
    func redisDatabaseReadWrite() {
        var conn = TestFixtures.makeConnection(type: .redis)
        conn.redisDatabase = 3
        #expect(conn.redisDatabase == 3)
    }

    // MARK: - additionalFields Dict

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

    @Test("usesAWSIAM reflects the awsAuth field")
    func usesAWSIAMReflectsField() {
        func connection(_ awsAuth: String?) -> DatabaseConnection {
            DatabaseConnection(name: "T", type: .mysql, additionalFields: awsAuth.map { ["awsAuth": $0] })
        }
        #expect(connection(nil).usesAWSIAM == false)
        #expect(connection("off").usesAWSIAM == false)
        #expect(connection("").usesAWSIAM == false)
        #expect(connection("accessKey").usesAWSIAM == true)
        #expect(connection("profile").usesAWSIAM == true)
    }

    @Test("Cassandra and ScyllaDB resolve AWS IAM in the driver, not via a token password")
    func resolvesAWSIAMInDriverByType() {
        func connection(_ type: DatabaseType) -> DatabaseConnection {
            DatabaseConnection(name: "T", type: type, additionalFields: ["awsAuth": "accessKey"])
        }
        #expect(connection(.cassandra).resolvesAWSIAMInDriver == true)
        #expect(connection(.scylladb).resolvesAWSIAMInDriver == true)
        #expect(connection(.mysql).resolvesAWSIAMInDriver == false)
        #expect(connection(.postgresql).resolvesAWSIAMInDriver == false)
        #expect(connection(.redis).resolvesAWSIAMInDriver == false)
    }
}
