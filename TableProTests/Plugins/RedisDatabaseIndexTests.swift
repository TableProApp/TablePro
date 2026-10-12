import Foundation
import Testing

struct RedisDatabaseIndexTests {
    @Test("the dedicated field wins over the database name")
    func fieldWins() {
        let index = RedisDatabaseIndex.resolve(additionalFields: ["redisDatabase": "3"], database: "0")
        #expect(index == 3)
    }

    @Test("the database name is used when the field is absent")
    func fallsBackToDatabase() {
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "7") == 7)
    }

    @Test("the dbN spelling the driver publishes resolves to that index")
    func acceptsDbPrefix() {
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "db4") == 4)
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "DB4") == 4)
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: " db4 ") == 4)
        #expect(RedisDatabaseIndex.resolve(additionalFields: ["redisDatabase": "db2"], database: "5") == 2)
    }

    @Test("an unusable value resolves to database zero")
    func defaultsToZero() {
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "") == 0)
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "cache") == 0)
        #expect(RedisDatabaseIndex.resolve(additionalFields: ["redisDatabase": ""], database: "db0") == 0)
    }

    /// `databases` accepts 1 to 2147483647 on redis-server 8.10.1 and `SELECT` parses a C int, so
    /// a server can hold any index up to one below Int32.max. Sixteen is only the default.
    @Test("every index a server can be configured to hold is selectable")
    func selectableSpansEveryConfigurableDatabase() {
        #expect(RedisDatabaseIndex.selectable.lowerBound == 0)
        #expect(RedisDatabaseIndex.selectable.upperBound == 2_147_483_646)
        #expect(RedisDatabaseIndex.selectable.count == Int(Int32.max))
        #expect(RedisDatabaseCount.limit == RedisDatabaseIndex.selectable.count)
    }

    @Test("parse rejects what is not an index so the switch can report it")
    func parseRejectsNonIndexes() {
        #expect(RedisDatabaseIndex.parse("db4") == 4)
        #expect(RedisDatabaseIndex.parse("4") == 4)
        #expect(RedisDatabaseIndex.parse("") == nil)
        #expect(RedisDatabaseIndex.parse("cache") == nil)
        #expect(RedisDatabaseIndex.parse("dbx") == nil)
    }

    @Test("selectableIndex accepts only an index a server can select")
    func selectableIndexHonoursTheRange() {
        #expect(RedisDatabaseIndex.selectableIndex("0") == 0)
        #expect(RedisDatabaseIndex.selectableIndex("db4") == 4)
        #expect(RedisDatabaseIndex.selectableIndex("2147483646") == 2_147_483_646)
        #expect(RedisDatabaseIndex.selectableIndex("-1") == nil)
        #expect(RedisDatabaseIndex.selectableIndex("2147483647") == nil)
        #expect(RedisDatabaseIndex.selectableIndex("abc") == nil)
    }
}
