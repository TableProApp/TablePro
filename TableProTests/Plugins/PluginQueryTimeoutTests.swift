import Testing

struct PluginQueryTimeoutTests {
    @Test("MongoDB clamps query timeout conversion before narrowing to Int32")
    func mongoDBConversionIsBounded() {
        let maximum = PluginQueryTimeout.maximumSeconds
        let maximumMilliseconds = Int32(maximum * 1_000)

        #expect(MongoDBTimeoutPolicy.queryTimeoutMilliseconds(seconds: 0) == 0)
        #expect(MongoDBTimeoutPolicy.queryTimeoutMilliseconds(seconds: -1) == 0)
        #expect(MongoDBTimeoutPolicy.queryTimeoutMilliseconds(seconds: maximum) == maximumMilliseconds)
        #expect(MongoDBTimeoutPolicy.queryTimeoutMilliseconds(seconds: maximum + 1) == maximumMilliseconds)
        #expect(MongoDBTimeoutPolicy.queryTimeoutMilliseconds(seconds: Int.max) == maximumMilliseconds)
    }

    @Test("SQLite clamps query timeout conversion before narrowing to Int32")
    func sqliteConversionIsBounded() {
        let maximum = PluginQueryTimeout.maximumSeconds
        let maximumMilliseconds = Int32(maximum * 1_000)

        #expect(SQLiteQueryTimeout.milliseconds(seconds: 0) == 0)
        #expect(SQLiteQueryTimeout.milliseconds(seconds: -1) == 0)
        #expect(SQLiteQueryTimeout.milliseconds(seconds: maximum) == maximumMilliseconds)
        #expect(SQLiteQueryTimeout.milliseconds(seconds: maximum + 1) == maximumMilliseconds)
        #expect(SQLiteQueryTimeout.milliseconds(seconds: Int.max) == maximumMilliseconds)
    }
}
