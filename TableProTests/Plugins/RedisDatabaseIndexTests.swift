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

    @Test("a non-numeric field falls back to the database name")
    func nonNumericField() {
        #expect(RedisDatabaseIndex.resolve(additionalFields: ["redisDatabase": "db2"], database: "5") == 5)
    }

    @Test("an unusable value resolves to database zero")
    func defaultsToZero() {
        #expect(RedisDatabaseIndex.resolve(additionalFields: [:], database: "") == 0)
        #expect(RedisDatabaseIndex.resolve(additionalFields: ["redisDatabase": ""], database: "db0") == 0)
    }
}
