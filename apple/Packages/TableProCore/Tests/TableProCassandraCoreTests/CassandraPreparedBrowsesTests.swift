import TableProCassandraCore
import Testing

struct CassandraBrowseSourceTests {
    @Test("A browse of named columns in a keyspace is reused", arguments: [
        "SELECT \"a\", \"b\" FROM \"ks\".\"t\"",
        "SELECT \"a\", TTL(\"b\") FROM \"ks\".\"t\" WHERE \"b\" = ? ALLOW FILTERING",
        "SELECT \"x FROM \"\"y\"\"\", \"a\" FROM \"ks\".\"t\""
    ])
    func qualifiedNamedColumnsAreReused(cql: String) throws {
        let source = try #require(CassandraBrowseSource(cql: cql))
        #expect(source.isReusable)
    }

    @Test("A browse whose table follows the session keyspace is prepared each time")
    func unqualifiedTableIsNotReused() throws {
        let source = try #require(CassandraBrowseSource(cql: "SELECT \"a\" FROM \"t\""))
        #expect(source.keyspace == nil)
        #expect(!source.isReusable)
    }

    @Test("A browse of every column is prepared each time, since its columns follow the table")
    func wildcardIsNotReused() throws {
        let source = try #require(CassandraBrowseSource(cql: "SELECT * FROM \"ks\".\"t\""))
        #expect(source.selectors == nil)
        #expect(!source.isReusable)
    }

    @Test("Text the plugin does not write is not a browse", arguments: [
        "SELECT a FROM ks.t",
        "select \"a\" from \"ks\".\"t\"",
        "SELECT \"a\" FROM \"ks\".\"t\"; DROP TABLE \"ks\".\"t\"",
        "SELECT COUNT(*) FROM \"ks\".\"t\"",
        "SELECT DISTINCT \"a\" FROM \"ks\".\"t\"",
        "SELECT WRITETIME(\"a\") FROM \"ks\".\"t\"",
        "SELECT \"a\" FROM \"ks\".",
        "SELECT \"a FROM \"ks\".\"t\"",
        "USE \"ks\"",
        "/* x */ SELECT \"a\" FROM \"ks\".\"t\""
    ])
    func otherTextIsNotABrowse(cql: String) {
        #expect(CassandraBrowseSource(cql: cql) == nil)
    }

    @Test("Qualifying names the keyspace and keeps the columns, the selectors and the filter")
    func qualifyingKeepsTheRest() throws {
        let source = try #require(CassandraBrowseSource(
            cql: "SELECT \"a\", TTL(\"b\") FROM \"t\" WHERE \"b\" = ? ALLOW FILTERING"
        ))
        let qualified = source.qualified(in: "shop")

        #expect(qualified == "SELECT \"a\", TTL(\"b\") FROM \"shop\".\"t\" WHERE \"b\" = ? ALLOW FILTERING")
        #expect(CassandraBrowseSource(cql: qualified)?.isReusable == true)
    }

    @Test("A keyspace or table holding a quote is quoted again")
    func qualifyingQuotesNames() throws {
        let source = try #require(CassandraBrowseSource(cql: "SELECT * FROM \"my\"\"table\""))
        #expect(source.table == "my\"table")
        #expect(source.qualified(in: "o\"k") == "SELECT * FROM \"o\"\"k\".\"my\"\"table\"")
    }
}

struct CassandraPreparedCacheTests {
    private typealias Cache = CassandraPreparedCache<Int>

    private func key(_ cql: String = "SELECT \"a\" FROM \"ks\".\"t\"", version: UInt32 = 1) -> Cache.Key {
        Cache.Key(cql: cql, schemaVersion: version)
    }

    @Test("A statement prepared once answers the next page")
    func reusesAStatement() {
        var cache = Cache()
        #expect(cache.insert(7, for: key()).isEmpty)
        #expect(cache.handle(for: key()) == 7)
    }

    @Test("Another keyspace is another statement")
    func keyspaceIsPartOfTheText() {
        var cache = Cache()
        _ = cache.insert(7, for: key("SELECT \"a\" FROM \"one\".\"t\""))
        #expect(cache.handle(for: key("SELECT \"a\" FROM \"two\".\"t\"")) == nil)
    }

    @Test("A newer schema snapshot misses and retires what was prepared under the older one")
    func schemaChangeRetiresStatements() {
        var cache = Cache()
        _ = cache.insert(1, for: key("SELECT \"a\" FROM \"ks\".\"t\"", version: 1))
        _ = cache.insert(2, for: key("SELECT \"b\" FROM \"ks\".\"t\"", version: 1))

        #expect(cache.handle(for: key("SELECT \"a\" FROM \"ks\".\"t\"", version: 2)) == nil)
        let released = cache.insert(3, for: key("SELECT \"a\" FROM \"ks\".\"t\"", version: 2))

        #expect(released.sorted() == [1, 2])
        #expect(cache.count == 1)
    }

    @Test("Past its capacity the statement used longest ago is released")
    func evictsLeastRecentlyUsed() {
        var cache = Cache(capacity: 2)
        _ = cache.insert(1, for: key("SELECT \"a\" FROM \"ks\".\"t\""))
        _ = cache.insert(2, for: key("SELECT \"b\" FROM \"ks\".\"t\""))
        _ = cache.handle(for: key("SELECT \"a\" FROM \"ks\".\"t\""))

        #expect(cache.insert(3, for: key("SELECT \"c\" FROM \"ks\".\"t\"")) == [2])
        #expect(cache.handle(for: key("SELECT \"a\" FROM \"ks\".\"t\"")) == 1)
    }

    @Test("Preparing a statement again releases the one it replaces")
    func replacingReleasesTheOldHandle() {
        var cache = Cache()
        _ = cache.insert(1, for: key())
        #expect(cache.insert(2, for: key()) == [1])
        #expect(cache.count == 1)
    }

    @Test("Removing a statement hands it back and leaves the others")
    func removeOne() {
        var cache = Cache()
        _ = cache.insert(1, for: key("SELECT \"a\" FROM \"ks\".\"t\""))
        _ = cache.insert(2, for: key("SELECT \"b\" FROM \"ks\".\"t\""))

        #expect(cache.remove(key("SELECT \"a\" FROM \"ks\".\"t\"")) == 1)
        #expect(cache.handle(for: key("SELECT \"b\" FROM \"ks\".\"t\"")) == 2)
        #expect(cache.count == 1)
    }

    @Test("Closing the session hands back every statement")
    func removeAllReleasesEverything() {
        var cache = Cache()
        _ = cache.insert(1, for: key("SELECT \"a\" FROM \"ks\".\"t\""))
        _ = cache.insert(2, for: key("SELECT \"b\" FROM \"ks\".\"t\""))

        #expect(cache.removeAll().sorted() == [1, 2])
        #expect(cache.handle(for: key("SELECT \"a\" FROM \"ks\".\"t\"")) == nil)
    }
}
