//
//  SetValueOptionsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct SetValueOptionsTests {
    private static func context(
        columnType: ColumnType?,
        isNullable: Bool = true,
        serverAssignsValue: Bool = false,
        isForeignKey: Bool = false,
        isWritable: Bool = true,
        displayFormat: ValueDisplayFormat? = nil,
        databaseType: DatabaseType = .postgresql,
        rowIsInserted: Bool = false,
        writer: CellWriterSupport = .host
    ) -> SetValueContext {
        SetValueContext(
            columnType: columnType,
            isNullable: isNullable,
            serverAssignsValue: serverAssignsValue,
            isForeignKey: isForeignKey,
            isWritable: isWritable,
            displayFormat: displayFormat,
            databaseType: databaseType,
            rowIsInserted: rowIsInserted,
            writer: writer
        )
    }

    @Test("A PostgreSQL uuid key with no default, written by the host, offers both UUIDs and nothing else")
    func reportersUUIDKey() {
        let context = Self.context(columnType: .text(rawType: "uuid"), isNullable: false)

        #expect(SetValueOptions.commands(for: context) == [.uuid(.v4), .uuid(.v7)])
        #expect(SetValueOptions.uuidForm(for: context) == .hyphenated)
    }

    @Test("A driver built before the capabilities existed gets no UUIDs and no expressions")
    func oldPluginWriter() {
        let uuid = Self.context(columnType: .text(rawType: "UUID"), databaseType: .mongodb, writer: .none)
        #expect(SetValueOptions.commands(for: uuid) == [.null])
        #expect(SetValueOptions.uuidForm(for: uuid) == nil)

        let date = Self.context(columnType: .date(rawType: "DATE"), databaseType: .oracle, writer: .none)
        #expect(SetValueOptions.commands(for: date) == [.null])
    }

    @Test("A driver that declares the capabilities gets them")
    func capablePluginWriter() {
        let writer = CellWriterSupport(acceptsExpressions: true, acceptsUUIDText: true)
        let date = Self.context(columnType: .date(rawType: "DATE"), databaseType: .oracle, writer: writer)
        let titles = SetValueOptions.commands(for: date).map(SetValueOptions.title(for:))
        #expect(titles == ["NULL", "SYSTIMESTAMP", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP", "SYSDATE", "CURRENT_DATE"])
    }

    @Test("The order is Empty, NULL, Default, expressions, then the UUIDs")
    func order() {
        let context = Self.context(
            columnType: .timestamp(rawType: "timestamptz"), serverAssignsValue: true, rowIsInserted: true
        )
        let titles = SetValueOptions.commands(for: context).map(SetValueOptions.title(for:))
        #expect(titles == ["NULL", "Default", "now()", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP"])

        let text = Self.context(columnType: .text(rawType: "varchar"), serverAssignsValue: true)
        #expect(SetValueOptions.commands(for: text) == [.empty, .null, .defaultValue])
    }

    @Test("Nothing at all for a column the app may not write")
    func notWritable() {
        let context = Self.context(columnType: .text(rawType: "uuid"), serverAssignsValue: true, isWritable: false)
        #expect(SetValueOptions.commands(for: context).isEmpty)
        #expect(SetValueOptions.uuidForm(for: context) == nil)
    }

    @Test("A foreign key never offers a new UUID")
    func foreignKey() {
        let context = Self.context(columnType: .text(rawType: "uuid"), isForeignKey: true)
        #expect(SetValueOptions.commands(for: context) == [.null])
    }

    @Test("timeuuid offers its server functions where the writer takes them, never a client UUID")
    func timeUUID() {
        let context = Self.context(columnType: .text(rawType: "timeuuid"), isNullable: false, databaseType: .cassandra)
        let titles = SetValueOptions.commands(for: context).map(SetValueOptions.title(for:))
        #expect(titles == ["now()", "currentTimeUUID()"])
    }

    @Test("Default on a saved row only where UPDATE takes DEFAULT")
    func defaultOnSavedRow() {
        let saved = Self.context(columnType: .text(rawType: "TEXT"), serverAssignsValue: true, databaseType: .sqlite)
        #expect(!SetValueOptions.commands(for: saved).contains(.defaultValue))

        let inserted = Self.context(
            columnType: .text(rawType: "TEXT"), serverAssignsValue: true, databaseType: .sqlite, rowIsInserted: true
        )
        #expect(SetValueOptions.commands(for: inserted).contains(.defaultValue))

        let postgres = Self.context(columnType: .text(rawType: "text"), serverAssignsValue: true)
        #expect(SetValueOptions.commands(for: postgres).contains(.defaultValue))
    }

    @Test("A text column the UUID format marks takes the form its values have")
    func formatOnlyColumn() {
        var context = Self.context(columnType: .text(rawType: "CHAR"), displayFormat: .uuid, databaseType: .mysql)
        #expect(SetValueOptions.uuidForm(for: context) == .hyphenated)

        context.sampleText = "0192f3a47b2c7d1e8f001a2b3c4d5e6f"
        #expect(SetValueOptions.uuidForm(for: context) == .compact)
        #expect(Array(SetValueOptions.commands(for: context).suffix(2)) == [.uuid(.v4), .uuid(.v7)])
    }

    @Test("An empty CHAR(32) column the UUID format marks takes the compact form from its schema")
    func formatOnlyColumnWithoutValues() {
        var context = Self.context(columnType: .text(rawType: "CHAR"), displayFormat: .uuid, databaseType: .mysql)
        context.declaredType = "CHAR(32)"
        #expect(SetValueOptions.uuidForm(for: context) == .compact)
    }

    @Test("Titles", arguments: [
        (SetValueCommand.empty, "Empty"), (.null, "NULL"), (.defaultValue, "Default"),
        (.uuid(.v4), "Generate UUID"), (.uuid(.v7), "Generate UUIDv7"),
        (.expression(CellExpression("now()", kinds: [.timestamp])), "now()"),
    ])
    func titles(command: SetValueCommand, title: String) {
        #expect(SetValueOptions.title(for: command) == title)
    }
}
