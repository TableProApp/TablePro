//
//  DatabaseConnectionRedisDatabaseIndexTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DatabaseConnectionRedisDatabaseIndexTests {
    private func redis(
        field: String? = nil,
        legacy: Int? = nil,
        database: String = "",
        mode: String? = nil
    ) -> DatabaseConnection {
        var fields: [String: String] = [:]
        fields["redisDatabase"] = field
        fields["redisMode"] = mode
        return DatabaseConnection(
            name: "cache",
            host: "localhost",
            port: 6_379,
            database: database,
            type: .redis,
            redisDatabase: legacy,
            additionalFields: fields
        )
    }

    @Test("The Database Index field is read first, in either spelling")
    func fieldComesFirst() {
        #expect(redis(field: "4").redisDatabaseIndex == 4)
        #expect(redis(field: "db4").redisDatabaseIndex == 4)
        #expect(redis(field: "5", legacy: 3).redisDatabaseIndex == 5)
    }

    @Test("A blank field falls back to the index saved before the field existed")
    func legacyValueFillsABlankField() {
        #expect(redis(field: "", legacy: 3).redisDatabaseIndex == 3)
        #expect(redis(legacy: 3, database: "db7").redisDatabaseIndex == 3)
    }

    @Test("With no field and no saved index, the database name is read the way iOS reads it")
    func databaseNameIsTheLastSource() {
        #expect(redis(database: "db7").redisDatabaseIndex == 7)
        #expect(redis(database: "7").redisDatabaseIndex == 7)
        #expect(redis(database: "cache").redisDatabaseIndex == 0)
        #expect(redis().redisDatabaseIndex == 0)
    }

    @Test("A negative index is kept so the server refuses it rather than db0 opening")
    func negativeIndexIsKept() {
        #expect(redis(field: "-1").redisDatabaseIndex == -1)
    }

    @Test("A cluster starts on database 0 whatever a hidden field still holds")
    func clusterStartsOnDatabaseZero() {
        let cluster = redis(field: "4", legacy: 4, database: "db4", mode: " Cluster ")
        #expect(cluster.redisDatabaseIndex == 0)
        #expect(cluster.configuredRedisDatabaseIndex == 4)
        #expect(redis(field: "4", mode: "sentinel").redisDatabaseIndex == 4)
        #expect(redis(field: "4", mode: "standalone").redisDatabaseIndex == 4)
    }

    @Test("The post-connect action resolves the Redis field through the same rule")
    func postConnectFieldUsesTheSameRule() {
        #expect(redis(field: "db2").databaseIndex(selectedBy: "redisDatabase") == 2)
        #expect(redis(field: "2", mode: "cluster").databaseIndex(selectedBy: "redisDatabase") == 0)
    }

    @Test("Another field reads that field and then the database name, never the Redis-only saved index")
    func otherFieldIgnoresTheRedisSavedIndex() {
        let connection = DatabaseConnection(
            name: "other",
            database: "db6",
            type: .redis,
            redisDatabase: 3,
            additionalFields: ["other": "8"]
        )
        #expect(connection.databaseIndex(selectedBy: "other") == 8)
        #expect(connection.databaseIndex(selectedBy: "missing") == 6)
    }
}
