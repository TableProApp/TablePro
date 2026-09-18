import Foundation
import TableProPluginKit
import Testing

private func generator(
    table: String = "t",
    columns: [String]
) -> BigQueryStatementGenerator {
    BigQueryStatementGenerator(projectId: "p", dataset: "d", tableName: table, columns: columns)
}

private func generate(
    _ generator: BigQueryStatementGenerator,
    _ changes: [PluginRowChange],
    insertedRowData: [Int: [PluginCellValue]] = [:],
    deleted: Set<Int> = [],
    inserted: Set<Int> = []
) -> [(statement: String, parameters: [PluginCellValue])]? {
    generator.generateStatements(
        from: changes,
        insertedRowData: insertedRowData,
        deletedRowIndices: deleted,
        insertedRowIndices: inserted
    )
}

@Suite("BigQueryStatementGenerator - INSERT")
struct BigQueryStatementGeneratorInsertTests {
    @Test("Every value is a placeholder bound in column order")
    func insertBindsEveryValue() throws {
        let gen = generator(table: "users", columns: ["id", "name", "age"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: ["1", "Alice", "30"]], inserted: [0]))
        #expect(result.count == 1)
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`users` (`id`, `name`, `age`) VALUES (?, ?, ?)")
        #expect(result[0].parameters == ["1", "Alice", "30"])
    }

    @Test("A NULL value is bound as a null parameter")
    func insertBindsNull() throws {
        let gen = generator(columns: ["a", "b"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: ["val", nil]], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`t` (`a`, `b`) VALUES (?, ?)")
        #expect(result[0].parameters == ["val", .null])
    }

    @Test("The DEFAULT sentinel leaves the column out of the INSERT")
    func insertSkipsDefaultSentinel() throws {
        let gen = generator(columns: ["id", "created_at", "name"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let row: [PluginCellValue] = ["7", .text(BigQueryStatementGenerator.defaultSentinel), "Bob"]
        let result = try #require(generate(gen, [change], insertedRowData: [0: row], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`t` (`id`, `name`) VALUES (?, ?)")
        #expect(result[0].parameters == ["7", "Bob"])
    }

    @Test("A row of only DEFAULT sentinels inserts DEFAULT into the first column")
    func insertAllDefaults() throws {
        let gen = generator(columns: ["id", "name"])
        let sentinel = PluginCellValue.text(BigQueryStatementGenerator.defaultSentinel)
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: [sentinel, sentinel]], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`t` (`id`) VALUES (DEFAULT)")
        #expect(result[0].parameters.isEmpty)
    }

    @Test("A bytes value is bound as a bytes parameter")
    func insertBindsBytes() throws {
        let gen = generator(columns: ["payload"])
        let bytes = Data([0x00, 0x27, 0xFF])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: [.bytes(bytes)]], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`t` (`payload`) VALUES (?)")
        #expect(result[0].parameters == [.bytes(bytes)])
    }

    @Test("A quote in a value never reaches the SQL text")
    func insertKeepsQuotesOutOfSQL() throws {
        let gen = generator(columns: ["name"])
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: ["x\\' OR TRUE --"]], inserted: [0]))
        #expect(!result[0].statement.contains("OR TRUE"))
        #expect(result[0].parameters == ["x\\' OR TRUE --"])
    }

    @Test("An INSERT without row data uses the changed cells")
    func insertFromCellChanges() throws {
        let gen = generator(columns: ["id", "name"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: nil, newValue: "Ann")],
            originalRow: nil
        )
        let result = try #require(generate(gen, [change], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `p`.`d`.`t` (`name`) VALUES (?)")
        #expect(result[0].parameters == ["Ann"])
    }
}

@Suite("BigQueryStatementGenerator - UPDATE")
struct BigQueryStatementGeneratorUpdateTests {
    @Test("SET values come before WHERE values in the parameter list")
    func basicUpdate() throws {
        let gen = generator(table: "users", columns: ["id", "name"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Bob")],
            originalRow: ["1", "Alice"]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result.count == 1)
        #expect(result[0].statement == "UPDATE `p`.`d`.`users` SET `name` = ? WHERE `id` = ? AND `name` = ?")
        #expect(result[0].parameters == ["Bob", "1", "Alice"])
    }

    @Test("Values that look like JSON stay in the WHERE clause")
    func keepsBracketValuesInWhere() throws {
        let gen = generator(columns: ["id", "label", "tags"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "id", oldValue: "1", newValue: "2")],
            originalRow: ["1", "{draft}", "[tag1]"]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result[0].statement.contains("`label` = ?"))
        #expect(result[0].statement.contains("`tags` = ?"))
        #expect(result[0].parameters == ["2", "1", "{draft}", "[tag1]"])
    }

    @Test("NULL original values use IS NULL in WHERE")
    func nullInWhere() throws {
        let gen = generator(columns: ["id", "note"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "note", oldValue: nil, newValue: "hello")],
            originalRow: ["1", nil]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result[0].statement == "UPDATE `p`.`d`.`t` SET `note` = ? WHERE `id` = ? AND `note` IS NULL")
        #expect(result[0].parameters == ["hello", "1"])
    }

    @Test("The DEFAULT sentinel writes DEFAULT in SET")
    func updateWritesDefault() throws {
        let gen = generator(columns: ["id", "status"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (
                    columnIndex: 1,
                    columnName: "status",
                    oldValue: "old",
                    newValue: .text(BigQueryStatementGenerator.defaultSentinel)
                )
            ],
            originalRow: ["1", "old"]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result[0].statement == "UPDATE `p`.`d`.`t` SET `status` = DEFAULT WHERE `id` = ? AND `status` = ?")
        #expect(result[0].parameters == ["1", "old"])
    }

    @Test("An UPDATE without an original row refuses the whole batch")
    func updateWithoutKeyRefusesBatch() {
        let gen = generator(columns: ["id", "name"])
        let insert = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let update = PluginRowChange(
            rowIndex: 1,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: nil
        )
        let result = generate(gen, [insert, update], insertedRowData: [0: ["1", "x"]], inserted: [0])
        #expect(result == nil)
    }

    @Test("The ownership probe with no cell changes gets an empty list")
    func ownershipProbe() {
        let gen = generator(columns: ["id"])
        let probe = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)
        let result = generate(gen, [probe])
        #expect(result?.isEmpty == true)
    }
}

@Suite("BigQueryStatementGenerator - DELETE")
struct BigQueryStatementGeneratorDeleteTests {
    @Test("Generates DELETE keyed on the original row")
    func basicDelete() throws {
        let gen = generator(columns: ["id", "name"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["42", "Alice"])
        let result = try #require(generate(gen, [change], deleted: [0]))
        #expect(result.count == 1)
        #expect(result[0].statement == "DELETE FROM `p`.`d`.`t` WHERE `id` = ? AND `name` = ?")
        #expect(result[0].parameters == ["42", "Alice"])
    }

    @Test("A bytes key is bound as a bytes parameter")
    func deleteBindsBytesKey() throws {
        let gen = generator(columns: ["hash"])
        let bytes = Data([0xDE, 0xAD])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.bytes(bytes)])
        let result = try #require(generate(gen, [change], deleted: [0]))
        #expect(result[0].parameters == [.bytes(bytes)])
    }

    @Test("A DELETE without an original row refuses the whole batch")
    func deleteWithoutOriginalRow() {
        let gen = generator(columns: ["id"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: nil)
        #expect(generate(gen, [change], deleted: [0]) == nil)
    }
}

@Suite("BigQueryStatementGenerator - Identifiers")
struct BigQueryStatementGeneratorIdentifierTests {
    @Test("Backticks and backslashes in names are escaped")
    func escapesIdentifiers() throws {
        let gen = BigQueryStatementGenerator(
            projectId: "my-proj",
            dataset: "d",
            tableName: "we`ird\\",
            columns: ["c`1"]
        )
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = try #require(generate(gen, [change], insertedRowData: [0: ["v"]], inserted: [0]))
        #expect(result[0].statement == "INSERT INTO `my-proj`.`d`.`we\\`ird\\\\` (`c\\`1`) VALUES (?)")
    }
}

@Suite("BigQueryStatementGenerator - Row Key")
struct BigQueryStatementGeneratorRowKeyTests {
    private func keyed(
        columns: [String],
        primaryKey: [String] = [],
        nonComparable: Set<String> = []
    ) -> BigQueryStatementGenerator {
        BigQueryStatementGenerator(
            projectId: "p",
            dataset: "d",
            tableName: "t",
            columns: columns,
            primaryKeyColumns: primaryKey,
            nonComparableColumns: nonComparable
        )
    }

    @Test("A declared primary key keys the UPDATE on exactly its columns")
    func updateKeysOnPrimaryKey() throws {
        let gen = keyed(columns: ["id", "name", "tags"], primaryKey: ["id"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: ["7", "a", "[1,2]"]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result[0].statement == "UPDATE `p`.`d`.`t` SET `name` = ? WHERE `id` = ?")
        #expect(result[0].parameters == ["b", "7"])
    }

    @Test("A composite primary key keys the DELETE on every key column, NULL as IS NULL")
    func deleteKeysOnCompositePrimaryKey() throws {
        let gen = keyed(columns: ["a", "b", "note"], primaryKey: ["b", "a"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", nil, "x"])
        let result = try #require(generate(gen, [change], deleted: [0]))
        #expect(result[0].statement == "DELETE FROM `p`.`d`.`t` WHERE `b` IS NULL AND `a` = ?")
        #expect(result[0].parameters == ["1"])
    }

    @Test("A primary key column missing from the result refuses the batch")
    func missingPrimaryKeyColumnRefuses() {
        let gen = keyed(columns: ["name"], primaryKey: ["id"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["a"])
        #expect(generate(gen, [change], deleted: [0]) == nil)
    }

    @Test("A primary key column past the end of the original row refuses the batch")
    func shortOriginalRowRefuses() {
        let gen = keyed(columns: ["name", "id"], primaryKey: ["id"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["a"])
        #expect(generate(gen, [change], deleted: [0]) == nil)
    }

    @Test("Without a primary key, ARRAY and JSON columns are left out of the key")
    func keylessSkipsNonComparable() throws {
        let gen = keyed(columns: ["id", "tags", "payload", "name"], nonComparable: ["tags", "payload"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 3, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: ["1", "[1]", "{}", "a"]
        )
        let result = try #require(generate(gen, [change]))
        #expect(result[0].statement == "UPDATE `p`.`d`.`t` SET `name` = ? WHERE `id` = ? AND `name` = ?")
        #expect(result[0].parameters == ["b", "1", "a"])
    }

    @Test("A column of unknown type stays in the key")
    func unknownTypeStaysInKey() throws {
        let gen = keyed(columns: ["id", "mystery"], nonComparable: ["tags"])
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: ["1", "?"])
        let result = try #require(generate(gen, [change], deleted: [0]))
        #expect(result[0].statement == "DELETE FROM `p`.`d`.`t` WHERE `id` = ? AND `mystery` = ?")
    }

    @Test("A row with no comparable column refuses the batch")
    func nothingComparableRefuses() {
        let gen = keyed(columns: ["tags", "shape"], nonComparable: ["tags", "shape"])
        let update = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "tags", oldValue: "[1]", newValue: "[2]")],
            originalRow: ["[1]", "POINT(0 0)"]
        )
        let delete = PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["[1]", "POINT(0 0)"])
        #expect(generate(gen, [update]) == nil)
        #expect(generate(gen, [delete], deleted: [1]) == nil)
    }
}
