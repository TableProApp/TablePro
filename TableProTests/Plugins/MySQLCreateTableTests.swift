//
//  MySQLCreateTableTests.swift
//  TableProTests
//
//  Tests for MySQL generateCreateTableSQL implementation.
//

import Foundation
import TableProPluginKit
import Testing

@testable import MySQLDriverPlugin

@Suite("MySQL CREATE TABLE SQL Generation")
struct MySQLCreateTableTests {
    private func makeDriver() -> MySQLPluginDriver {
        MySQLPluginDriver()
    }

    @Test("basic table with single column")
    func basicSingleColumn() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "users",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "INT", isNullable: false)
            ]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)
        #expect(sql != nil)
        #expect(sql!.contains("CREATE TABLE `users`"))
        #expect(sql!.contains("`id` INT NOT NULL"))
    }

    @Test("empty columns returns nil")
    func emptyColumns() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(tableName: "empty", columns: [])
        #expect(driver.generateCreateTableSQL(definition: definition) == nil)
    }

    @Test("auto increment adds PRIMARY KEY")
    func autoIncrementPK() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "posts",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "BIGINT", isNullable: false, autoIncrement: true),
                PluginColumnDefinition(name: "title", dataType: "VARCHAR(255)", isNullable: false)
            ]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("AUTO_INCREMENT"))
        #expect(sql.contains("PRIMARY KEY (`id`)"))
    }

    @Test("explicit primary key columns")
    func explicitPrimaryKey() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "composite",
            columns: [
                PluginColumnDefinition(name: "user_id", dataType: "INT", isNullable: false),
                PluginColumnDefinition(name: "role_id", dataType: "INT", isNullable: false)
            ],
            primaryKeyColumns: ["user_id", "role_id"]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("PRIMARY KEY (`user_id`, `role_id`)"))
    }

    @Test("table options: engine, charset, collation")
    func tableOptions() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "t",
            columns: [PluginColumnDefinition(name: "id", dataType: "INT")],
            engine: "MyISAM",
            charset: "latin1",
            collation: "latin1_swedish_ci"
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("ENGINE=MyISAM"))
        #expect(sql.contains("DEFAULT CHARSET=latin1"))
        #expect(sql.contains("COLLATE=latin1_swedish_ci"))
    }

    @Test("IF NOT EXISTS flag")
    func ifNotExists() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "t",
            columns: [PluginColumnDefinition(name: "id", dataType: "INT")],
            ifNotExists: true
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("CREATE TABLE IF NOT EXISTS"))
    }

    @Test("column with UNSIGNED, DEFAULT, COMMENT")
    func fullColumnDefinition() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "products",
            columns: [
                PluginColumnDefinition(
                    name: "price",
                    dataType: "DECIMAL(10,2)",
                    isNullable: false,
                    defaultValue: "0.00",
                    comment: "Product price",
                    unsigned: true
                )
            ]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("UNSIGNED"))
        #expect(sql.contains("NOT NULL"))
        #expect(sql.contains("COMMENT"))
    }

    @Test("index generation")
    func indexGeneration() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "t",
            columns: [
                PluginColumnDefinition(name: "email", dataType: "VARCHAR(255)")
            ],
            indexes: [
                PluginIndexDefinition(name: "idx_email", columns: ["email"], isUnique: true)
            ]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("UNIQUE INDEX `idx_email` (`email`)"))
    }

    @Test("foreign key generation")
    func foreignKeyGeneration() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "orders",
            columns: [
                PluginColumnDefinition(name: "user_id", dataType: "INT", isNullable: false)
            ],
            foreignKeys: [
                PluginForeignKeyDefinition(
                    name: "fk_user",
                    columns: ["user_id"],
                    referencedTable: "users",
                    referencedColumns: ["id"],
                    onDelete: "CASCADE",
                    onUpdate: "NO ACTION"
                )
            ]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("CONSTRAINT `fk_user` FOREIGN KEY (`user_id`)"))
        #expect(sql.contains("REFERENCES `users` (`id`)"))
        #expect(sql.contains("ON DELETE CASCADE"))
    }

    @Test("backtick in table name is escaped")
    func backtickEscaping() {
        let driver = makeDriver()
        let definition = PluginCreateTableDefinition(
            tableName: "my`table",
            columns: [PluginColumnDefinition(name: "col`name", dataType: "INT")]
        )

        let sql = driver.generateCreateTableSQL(definition: definition)!
        #expect(sql.contains("`my``table`"))
        #expect(sql.contains("`col``name`"))
    }
}
