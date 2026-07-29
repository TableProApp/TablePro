//
//  SocketPathPlaceholderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Default Unix socket path per database type")
struct SocketPathPlaceholderTests {
    @Test("MySQL and MariaDB use the mysqld socket")
    func mysqlFamilyUsesMysqldSocket() {
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .mysql) == "/var/run/mysqld/mysqld.sock")
        #expect(PluginManager.shared.defaultUnixSocketPath(for: .mariadb) == "/var/run/mysqld/mysqld.sock")
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

    @Test("Unknown type has no default")
    func unknownTypeHasNoDefault() {
        let unknown = DatabaseType(rawValue: "FuturePlugin")
        #expect(PluginManager.shared.defaultUnixSocketPath(for: unknown) == nil)
    }
}
