//
//  CassandraPreparedCacheTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraPreparedCacheTests {
    private typealias Cache = CassandraPreparedCache<Int>

    private func key(_ cql: String = "SELECT a FROM t", keyspace: String? = "ks", version: UInt32 = 1) -> Cache.Key {
        Cache.Key(keyspace: keyspace, cql: cql, schemaVersion: version)
    }

    @Test("A statement prepared once answers the next page")
    func reusesAStatement() {
        var cache = Cache()
        #expect(cache.insert(7, for: key()).isEmpty)
        #expect(cache.handle(for: key()) == 7)
    }

    @Test("The same text in another keyspace is another statement")
    func keyspaceSeparatesStatements() {
        var cache = Cache()
        _ = cache.insert(7, for: key(keyspace: "one"))
        #expect(cache.handle(for: key(keyspace: "two")) == nil)
    }

    @Test("A newer schema snapshot misses and retires what was prepared under the older one")
    func schemaChangeRetiresStatements() {
        var cache = Cache()
        _ = cache.insert(1, for: key("SELECT a FROM t", version: 1))
        _ = cache.insert(2, for: key("SELECT b FROM t", version: 1))

        #expect(cache.handle(for: key("SELECT a FROM t", version: 2)) == nil)
        let released = cache.insert(3, for: key("SELECT a FROM t", version: 2))

        #expect(released.sorted() == [1, 2])
        #expect(cache.count == 1)
    }

    @Test("Past its capacity the statement used longest ago is released")
    func evictsLeastRecentlyUsed() {
        var cache = Cache(capacity: 2)
        _ = cache.insert(1, for: key("SELECT a FROM t"))
        _ = cache.insert(2, for: key("SELECT b FROM t"))
        _ = cache.handle(for: key("SELECT a FROM t"))

        #expect(cache.insert(3, for: key("SELECT c FROM t")) == [2])
        #expect(cache.handle(for: key("SELECT a FROM t")) == 1)
    }

    @Test("Preparing a statement again releases the one it replaces")
    func replacingReleasesTheOldHandle() {
        var cache = Cache()
        _ = cache.insert(1, for: key())
        #expect(cache.insert(2, for: key()) == [1])
        #expect(cache.count == 1)
    }

    @Test("Closing the session hands back every statement")
    func removeAllReleasesEverything() {
        var cache = Cache()
        _ = cache.insert(1, for: key("SELECT a FROM t"))
        _ = cache.insert(2, for: key("SELECT b FROM t"))

        #expect(cache.removeAll().sorted() == [1, 2])
        #expect(cache.handle(for: key("SELECT a FROM t")) == nil)
    }

    @Test("A read leaves the session's browse state alone", arguments: ["SELECT a FROM t", "  select a from t", "(SELECT a FROM t)"])
    func readsKeepBrowseState(cql: String) {
        #expect(CassandraPreparedReuse.isRead(cql: cql))
    }

    @Test("A statement that can change the keyspace or the rows is not a read", arguments: [
        "USE other",
        "use \"other\"",
        "/* switch */ USE other",
        "INSERT INTO t (a) VALUES (1)",
        "ALTER TABLE t ADD b int"
    ])
    func othersResetBrowseState(cql: String) {
        #expect(!CassandraPreparedReuse.isRead(cql: cql))
    }

    @Test("A select list that names its columns is reused", arguments: [
        "SELECT \"a\", \"b\" FROM \"ks\".\"t\"",
        "select a from t",
        "SELECT \"a*b\" FROM t",
        "SELECT \"x from y\", a FROM t",
        "SELECT a FROM t WHERE b = '*' ALLOW FILTERING",
        "SELECT TTL(\"a\") FROM t"
    ])
    func namedColumnsAreReusable(cql: String) {
        #expect(CassandraPreparedReuse.isReusable(cql: cql))
    }

    @Test("A select list that follows the table is prepared again", arguments: [
        "SELECT * FROM t",
        "select * from t",
        "SELECT DISTINCT * FROM t",
        "SELECT \"x from y\", * FROM t",
        "SELECT COUNT(*) FROM t",
        "UPDATE t SET a = 1"
    ])
    func wildcardIsNotReusable(cql: String) {
        #expect(!CassandraPreparedReuse.isReusable(cql: cql))
    }
}
