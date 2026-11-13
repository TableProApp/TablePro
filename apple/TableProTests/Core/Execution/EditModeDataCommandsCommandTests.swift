//
//  EditModeDataCommandsCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct EditModeDataCommandsCommandTests {
    private func statement(_ sql: String, databaseType: DatabaseType) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: .readWrite,
            loadsExtensions: false,
            allowsDestructive: false,
            allowsOnlyDataStatements: true
        )
    }

    private func refusal(_ sql: String, on databaseType: DatabaseType) -> ExternalStatementGateError? {
        do {
            _ = try ExternalStatementGate.classify(statement(sql, databaseType: databaseType))
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    @Test("Edit refuses a Redis command that changes no data", arguments: [
        "ACL SETUSER bob on >pw +@all ~*", #""\x41CL" SETUSER bob on"#,
        "SELECT 3", "CLIENT SETNAME x", "CLIENT REPLY OFF", "HELLO 3",
        "MULTI", "WATCH k",
        "SLOWLOG RESET", "MEMORY PURGE", "HOTKEYS START METRICS 1 CPU", "CLIENT KILL ID 7", "FT.CONFIG SET TIMEOUT 1",
        "PFDEBUG GETREG h",
        "READWRITE", "SEARCH.CLUSTERREFRESH", "TIMESERIES.REFRESHCLUSTER",
        "FT.CREATE idx ON HASH SCHEMA name TEXT", "FT.ALIASADD a idx", "FT.SYNUPDATE idx g a b",
        "TS.CREATERULE a b AGGREGATION avg 60000",
        "PUBLISH ch hi", "SUBSCRIBE ch",
        "DB 2 ACL SETUSER bob on", "OUTSIDEBLOCK CLIENT KILL ID 7", "MUSTAPPLY",
        "SOME.NEW.COMMAND x", "XGROUP", #"SET "a b"#,
    ])
    func redisRefusesNonDataCommands(sql: String) {
        #expect(refusal(sql, on: .redis) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit leaves Redis server code to the code rule", arguments: [#"EVAL "return 1" 0"#, "FCALL_RO f 0"])
    func redisCodeStaysRefused(sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .redis))
        #expect(refusal(sql, on: .redis) != nil)
    }

    @Test("Edit runs Redis reads and data changes", arguments: [
        "SET k v EX 10", "EXPIRE k 60", "RENAME a b", "HSET h f v", "HEXPIRE h 60 FIELDS 1 f", "LPUSH l a", "SADD s a",
        "ZADD z 1 a", "XADD s * f v", "XGROUP CREATE s g $ MKSTREAM", "SETBIT b 7 1", "GEOADD g 13.4 52.5 berlin",
        "PFADD h a", "ARSET a 0 x", #"JSON.SET doc $ '{"a":1}'"#, "TS.ADD t * 1", "BF.ADD bf a",
        "VADD vs VALUES 2 0.1 0.2 e1",
        "DB 1 SET k v", "MUSTAPPLY SET k v NX",
        "GET k", "FT.SEARCH idx *", "FT.AGGREGATE idx * LOAD 1 @name", "TS.MRANGE - + FILTER a=b", "HTTL h FIELDS 1 f",
    ])
    func redisRunsDataWork(sql: String) {
        #expect(refusal(sql, on: .redis) == nil)
    }

    @Test("Edit refuses a Memcached command that changes the server", arguments: [
        "stats reset", "stats detail on", "stats sizes_enable", "verbosity 1", "mg k v", #""\x73tats" reset"#,
    ])
    func memcachedRefusesServerCommands(sql: String) {
        #expect(refusal(sql, on: .memcached) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Memcached reads and data changes", arguments: [
        "set k 0 60 v", "add k 0 0 v", "cas k 0 0 123 v", "append k 0 0 x", "incr n 1", "touch k 60", "gat 60 k",
        "get k", "stats", "stats items",
    ])
    func memcachedRunsDataWork(sql: String) {
        #expect(refusal(sql, on: .memcached) == nil)
    }

    @Test("Edit runs a Memcached delete, which takes one key, and refuses flush_all as destructive")
    func memcachedDeleteRunsInEdit() {
        #expect(QueryClassifier.isDataStatement("delete k", databaseType: .memcached))
        #expect(refusal("delete k", on: .memcached) == nil)
        #expect(refusal("flush_all", on: .memcached) == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("Edit refuses an etcd command that changes no data", arguments: [
        "user add mallory pw", "role add admin", "user grant-role mallory root", "user revoke-role app reader",
        "auth enable", "select 1", "frobnicate x",
    ])
    func etcdRefusesNonDataCommands(sql: String) {
        #expect(refusal(sql, on: .etcd) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit still refuses the etcd commands refused before", arguments: [
        "auth disable", "user delete app", "compaction 5", "lease revoke 694da1d22d63c20a", "del app/ --prefix", "defrag",
    ])
    func etcdKeepsEarlierRefusals(sql: String) {
        #expect(refusal(sql, on: .etcd) != nil)
    }

    @Test("Edit refuses an etcd del of a prefix or a range as destructive", arguments: [
        "del app/ --prefix", "del --prefix app/", "del app/a app/z", "del --from-key app/a", "del app/ --prefix=true",
    ])
    func etcdManyKeyDeleteIsDestructive(sql: String) {
        #expect(refusal(sql, on: .etcd) == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("Edit runs etcd reads and data changes", arguments: [
        "put app/a 1", "put app/a 1 --lease=694da1d22d63c20a", "create app/b 2", "del app/a", "delete app/a",
        "lease grant 60", "lease keep-alive 694da1d22d63c20a", "get app/ --prefix", "user list",
    ])
    func etcdRunsDataWork(sql: String) {
        #expect(refusal(sql, on: .etcd) == nil)
    }

    @Test("Edit refuses text KafkaQL cannot parse")
    func kafkaRefusesUnparsedText() {
        #expect(refusal("ALTER TOPIC orders", on: .kafka) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit refuses DROP TOPIC as destructive")
    func kafkaDropTopicStaysDestructive() {
        #expect(refusal("DROP TOPIC \"orders\"", on: .kafka) == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("Edit runs KafkaQL reads and PRODUCE", arguments: [
        "PRODUCE INTO \"orders\" KEY \"k\" VALUE \"v\"", "CONSUME \"orders\" FROM OLDEST LIMIT 10",
        "SELECT * FROM orders", "SHOW TOPICS", "DESCRIBE GROUP \"g\"",
    ])
    func kafkaRunsDataWork(sql: String) {
        #expect(refusal(sql, on: .kafka) == nil)
    }

    @Test("Edit refuses PRODUCE into a topic another service keeps its state in", arguments: [
        "PRODUCE INTO \"_schemas\" KEY \"k\" VALUE \"v\"",
        "PRODUCE INTO \"_confluent-ksql-default__command_topic\" VALUE \"v\"",
        "PRODUCE INTO \"__consumer_offsets\" VALUE \"v\"",
        "PRODUCE INTO \"connect-configs\" KEY \"connector-sink\" VALUE \"{}\"",
        "PRODUCE INTO \"connect-offsets\" VALUE \"v\"",
        "PRODUCE INTO \"connect-status\" VALUE \"v\"",
        "PRODUCE INTO \"mm2-configs.east.internal\" VALUE \"v\"",
        "PRODUCE INTO \"east.checkpoints.internal\" VALUE \"v\"",
        "PRODUCE INTO \".hidden\" VALUE \"v\"",
        "PRODUCE INTO \"orders-app-counts-store-changelog\" VALUE \"v\"",
        "PRODUCE INTO \"orders-app-KSTREAM-AGGREGATE-0000000003-repartition\" VALUE \"v\"",
    ])
    func kafkaRefusesServiceTopics(sql: String) {
        #expect(refusal(sql, on: .kafka) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("A topic that only looks like a service's is a user's", arguments: [
        "PRODUCE INTO \"schemas\" VALUE \"v\"",
        "PRODUCE INTO \"my_connect-configs\" VALUE \"v\"",
        "PRODUCE INTO \"orders.internal\" VALUE \"v\"",
        "CONSUME \"_schemas\" FROM OLDEST LIMIT 10",
    ])
    func kafkaRunsUserTopics(sql: String) {
        #expect(refusal(sql, on: .kafka) == nil)
    }
}
