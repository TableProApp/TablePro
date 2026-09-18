import Foundation
import Testing

@Suite("Redis database index")
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

    @Test("parse rejects what is not an index so the switch can report it")
    func parseRejectsNonIndexes() {
        #expect(RedisDatabaseIndex.parse("db4") == 4)
        #expect(RedisDatabaseIndex.parse("4") == 4)
        #expect(RedisDatabaseIndex.parse("") == nil)
        #expect(RedisDatabaseIndex.parse("cache") == nil)
        #expect(RedisDatabaseIndex.parse("dbx") == nil)
    }
}
