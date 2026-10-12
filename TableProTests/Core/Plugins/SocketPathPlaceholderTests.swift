//
//  SocketPathPlaceholderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SocketPathPlaceholderTests {
    @Test("MySQL and MariaDB use the mysqld socket")
    func mysqlFamilyUsesMysqldSocket() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .mysql) == "/var/run/mysqld/mysqld.sock")
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .mariadb) == "/var/run/mysqld/mysqld.sock")
    }

    @Test("TiDB and Databend have no default Unix socket")
    func mysqlProtocolVariantsHaveNoSocket() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .tidb) == nil)
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .databend) == nil)
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .oceanbase) == nil)
    }

    @Test("PostgreSQL uses the PGSQL socket")
    func postgresqlUsesPgsqlSocket() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .postgresql) == "/var/run/postgresql/.s.PGSQL.5432")
    }

    @Test("Redis uses the redis socket")
    func redisUsesRedisSocket() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .redis) == "/var/run/redis/redis.sock")
    }

    @Test("Types without a socket convention have no default")
    func typesWithoutSocketHaveNoDefault() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .sqlite) == nil)
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .clickhouse) == nil)
    }

    @Test("MySQL and MariaDB offer a socket on this Mac at the mysql client's default path")
    func mysqlFamilyHasALocalSocket() {
        #expect(PluginManager.shared.defaultLocalSocketPath(for: .mysql) == "/tmp/mysql.sock")
        #expect(PluginManager.shared.defaultLocalSocketPath(for: .mariadb) == "/tmp/mysql.sock")
    }

    @Test("No other type offers a socket on this Mac")
    func otherTypesHaveNoLocalSocket() {
        let unknown = DatabaseType(rawValue: "FuturePlugin")
        for type in [DatabaseType.tidb, .databend, .oceanbase, .postgresql, .redis, .sqlite, unknown] {
            #expect(PluginManager.shared.defaultLocalSocketPath(for: type) == nil, "\(type.rawValue)")
        }
    }

    @Test("Unknown type has no default")
    func unknownTypeHasNoDefault() {
        let unknown = DatabaseType(rawValue: "FuturePlugin")
        #expect(PluginManager.shared.defaultUnixSocketPath(for: unknown) == nil)
    }
}
