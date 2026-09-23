import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB write statements")
struct DynamoDBWriteStatementsTests {
    typealias CellChange = (columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)

    private let writer = DynamoDBWriteStatements(
        table: "Orders",
        columns: ["pk", "sk", "name", "total", "o'clock"],
        keyColumns: ["pk", "sk"]
    )

    private let originalRow: [PluginCellValue] = ["p1", "7", "Ann", "10", .null]

    private func cell(
        _ index: Int,
        _ name: String,
        _ old: PluginCellValue,
        _ new: PluginCellValue
    ) -> CellChange {
        (columnIndex: index, columnName: name, oldValue: old, newValue: new)
    }

    private func update(_ cells: [CellChange], row: Int = 0) -> PluginRowChange {
        PluginRowChange(rowIndex: row, type: .update, cellChanges: cells, originalRow: originalRow)
    }

    private func generate(
        _ changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]] = [:],
        deleted: Set<Int> = [],
        inserted: Set<Int> = []
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        writer.statements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deleted,
            insertedRowIndices: inserted
        )
    }

    private static func schema() throws -> DynamoDBTableSchema {
        try DynamoDBTableSchema(describeTableResponse: DynamoDBJSON.parse("""
            {"Table": {
              "TableName": "Orders",
              "KeySchema": [
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
              ],
              "AttributeDefinitions": [
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "N"}
              ]
            }}
            """))
    }

    // MARK: - UPDATE

    @Test("A changed value is set, guarded by its loaded value and keyed by the original row")
    func updateChangedValue() throws {
        let result = generate([update([cell(2, "name", "Ann", "Bea")])])
        let statement = try #require(result.first)
        #expect(result.count == 1)
        #expect(statement.statement == "UPDATE \"Orders\" SET \"name\" = ? WHERE \"pk\" = ? AND \"sk\" = ? AND \"name\" = ?")
        #expect(statement.parameters == ["Bea", "p1", "7", "Ann"])
    }

    @Test("A value set to NULL is removed, still guarded by its loaded value")
    func updateToNullRemoves() throws {
        let statement = try #require(generate([update([cell(3, "total", "10", .null)])]).first)
        #expect(statement.statement == "UPDATE \"Orders\" REMOVE \"total\" WHERE \"pk\" = ? AND \"sk\" = ? AND \"total\" = ?")
        #expect(statement.parameters == ["p1", "7", "10"])
    }

    @Test("SET comes before REMOVE, and parameters run SET values, key, then guards")
    func updateParameterOrder() throws {
        let statement = try #require(generate([update([
            cell(2, "name", "Ann", "Bea"),
            cell(3, "total", "10", .null),
            cell(4, "o'clock", .null, "noon")
        ])]).first)
        #expect(statement.statement == """
            UPDATE "Orders" SET "name" = ?, "o'clock" = ? REMOVE "total" \
            WHERE "pk" = ? AND "sk" = ? AND "name" = ? AND "total" = ?
            """)
        #expect(statement.parameters == ["Bea", "noon", "p1", "7", "Ann", "10"])
    }

    @Test("A value that was NULL is set without a guard")
    func updateFromNullHasNoGuard() throws {
        let statement = try #require(generate([update([cell(4, "o'clock", .null, "noon")])]).first)
        #expect(statement.statement == "UPDATE \"Orders\" SET \"o'clock\" = ? WHERE \"pk\" = ? AND \"sk\" = ?")
        #expect(statement.parameters == ["noon", "p1", "7"])
    }

    @Test("A binary value is guarded and set as bytes")
    func updateBinaryValue() throws {
        let old = Data([0x01, 0x02])
        let new = Data([0x03])
        let statement = try #require(generate([update([cell(3, "total", .bytes(old), .bytes(new))])]).first)
        #expect(statement.parameters == [.bytes(new), "p1", "7", .bytes(old)])
    }

    @Test("A changed key is still written, keyed by the original values and never guarded")
    func updateChangedKey() throws {
        let statement = try #require(generate([update([cell(0, "pk", "p1", "p2")])]).first)
        #expect(statement.statement == "UPDATE \"Orders\" SET \"pk\" = ? WHERE \"pk\" = ? AND \"sk\" = ?")
        #expect(statement.parameters == ["p2", "p1", "7"])
    }

    @Test("The binder refuses the key change the generator writes")
    func changedKeyIsRefusedWhenBound() throws {
        let statement = try #require(generate([update([cell(1, "sk", "7", "8")])]).first)
        let roles = DynamoDBPartiQL.parameterRoles(in: statement.statement)
        #expect(roles == [
            .assigned(DynamoDBAttributePath(attribute: "sk")),
            .compared(DynamoDBAttributePath(attribute: "pk")),
            .compared(DynamoDBAttributePath(attribute: "sk"))
        ])

        let binder = DynamoDBParameterBinder(schema: try Self.schema(), observedTypes: [:], currentItem: nil)
        #expect(throws: DynamoDBError.self) {
            try binder.bind(statement.parameters, roles: roles)
        }
    }

    @Test("The roles read from a generated UPDATE line up with its parameters")
    func updateRolesLineUp() throws {
        let statement = try #require(generate([update([
            cell(2, "name", "Ann", "Bea"),
            cell(3, "total", "10", .null),
            cell(4, "o'clock", .null, "noon")
        ])]).first)
        let roles = DynamoDBPartiQL.parameterRoles(in: statement.statement)
        #expect(roles == [
            .assigned(DynamoDBAttributePath(attribute: "name")), .assigned(DynamoDBAttributePath(attribute: "o'clock")),
            .compared(DynamoDBAttributePath(attribute: "pk")),
            .compared(DynamoDBAttributePath(attribute: "sk")),
            .compared(DynamoDBAttributePath(attribute: "name")),
            .compared(DynamoDBAttributePath(attribute: "total"))
        ])
        #expect(roles.count == statement.parameters.count)
    }

    @Test("An update with no original row or no changed cells writes nothing")
    func updateWithoutOriginalOrCells() {
        let noOriginal = PluginRowChange(
            rowIndex: 0, type: .update, cellChanges: [cell(2, "name", "Ann", "Bea")], originalRow: nil
        )
        let noCells = PluginRowChange(rowIndex: 1, type: .update, cellChanges: [], originalRow: originalRow)
        #expect(generate([noOriginal, noCells]).isEmpty)
    }

    @Test("Table and attribute names with double quotes are escaped")
    func updateQuotesNames() throws {
        let quoted = DynamoDBWriteStatements(table: "Or\"ders", columns: ["p\"k", "a\"b"], keyColumns: ["p\"k"])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [cell(1, "a\"b", "x", "y")],
            originalRow: ["k", "x"]
        )
        let result = quoted.statements(
            for: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let statement = try #require(result.first)
        #expect(statement.statement == "UPDATE \"Or\"\"ders\" SET \"a\"\"b\" = ? WHERE \"p\"\"k\" = ? AND \"a\"\"b\" = ?")
        #expect(DynamoDBPartiQL.target(of: statement.statement)?.table == "Or\"ders")
        #expect(DynamoDBPartiQL.parameterRoles(in: statement.statement) == [
            .assigned(DynamoDBAttributePath(attribute: "a\"b")),
            .compared(DynamoDBAttributePath(attribute: "p\"k")),
            .compared(DynamoDBAttributePath(attribute: "a\"b"))
        ])
    }

    // MARK: - INSERT

    @Test("An insert leaves out NULL cells and the default sentinel")
    func insertSkipsNullAndDefault() {
        let data = Data([0xFF])
        let result = writer.insert(row: ["p1", "7", .null, "__DEFAULT__", .bytes(data)])
        #expect(result.statement == "INSERT INTO \"Orders\" VALUE {'pk': ?, 'sk': ?, 'o''clock': ?}")
        #expect(result.parameters == ["p1", "7", .bytes(data)])
    }

    @Test("An empty string is inserted, only the exact sentinel is skipped")
    func insertKeepsEmptyText() {
        let result = writer.insert(row: ["p1", "7", "", "__default__", " __DEFAULT__"])
        #expect(result.statement == "INSERT INTO \"Orders\" VALUE {'pk': ?, 'sk': ?, 'name': ?, 'total': ?, 'o''clock': ?}")
        #expect(result.parameters == ["p1", "7", "", "__default__", " __DEFAULT__"])
    }

    @Test("The roles read from a generated INSERT name each attribute")
    func insertRolesLineUp() {
        let result = writer.insert(row: ["p1", "7", .null, "10", "noon"])
        #expect(DynamoDBPartiQL.parameterRoles(in: result.statement) == [
            .inserted("pk"), .inserted("sk"), .inserted("total"), .inserted("o'clock")
        ])
    }

    @Test("Single quotes in attribute names are doubled")
    func literalDoublesQuotes() {
        #expect(DynamoDBWriteStatements.literal("name") == "'name'")
        #expect(DynamoDBWriteStatements.literal("it's") == "'it''s'")
        #expect(DynamoDBWriteStatements.literal("''") == "''''''")
    }

    @Test("An inserted row with no row data is built from its changed cells")
    func insertFromCellChanges() throws {
        let change = PluginRowChange(
            rowIndex: 5,
            type: .insert,
            cellChanges: [cell(0, "pk", .null, "p9"), cell(2, "name", .null, "Cy"), cell(9, "ghost", .null, "z")],
            originalRow: nil
        )
        let statement = try #require(generate([change], inserted: [5]).first)
        #expect(statement.statement == "INSERT INTO \"Orders\" VALUE {'pk': ?, 'name': ?}")
        #expect(statement.parameters == ["p9", "Cy"])
    }

    @Test("Row data takes precedence over the changed cells of an inserted row")
    func insertPrefersRowData() throws {
        let change = PluginRowChange(
            rowIndex: 5, type: .insert, cellChanges: [cell(0, "pk", .null, "stale")], originalRow: nil
        )
        let statement = try #require(generate([change], insertedRowData: [5: ["p5", "1"]], inserted: [5]).first)
        #expect(statement.statement == "INSERT INTO \"Orders\" VALUE {'pk': ?, 'sk': ?}")
        #expect(statement.parameters == ["p5", "1"])
    }

    // MARK: - DELETE

    @Test("A delete is keyed by the original row and returns the old item")
    func deleteStatement() throws {
        let change = PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: originalRow)
        let statement = try #require(generate([change], deleted: [2]).first)
        #expect(statement.statement == "DELETE FROM \"Orders\" WHERE \"pk\" = ? AND \"sk\" = ? RETURNING ALL OLD *")
        #expect(statement.parameters == ["p1", "7"])
        #expect(DynamoDBPartiQL.hasReturning(statement.statement))
        #expect(DynamoDBPartiQL.parameterRoles(in: statement.statement) == [
            .compared(DynamoDBAttributePath(attribute: "pk")),
            .compared(DynamoDBAttributePath(attribute: "sk"))
        ])
    }

    @Test("A delete with no original row writes nothing")
    func deleteWithoutOriginal() {
        let change = PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: nil)
        #expect(generate([change], deleted: [2]).isEmpty)
    }

    // MARK: - Batches

    @Test("Only rows still marked inserted or deleted are written, in change order")
    func statementsRespectIndices() {
        let changes = [
            PluginRowChange(rowIndex: 3, type: .insert, cellChanges: [], originalRow: nil),
            PluginRowChange(rowIndex: 4, type: .insert, cellChanges: [], originalRow: nil),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: ["d1", "1", .null, .null, .null]),
            PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: ["d2", "2", .null, .null, .null]),
            update([cell(2, "name", "Ann", "Bea")])
        ]
        let result = generate(
            changes,
            insertedRowData: [3: ["n3", "3"], 4: ["n4", "4"]],
            deleted: [2],
            inserted: [3]
        )
        #expect(result.map(\.statement) == [
            "INSERT INTO \"Orders\" VALUE {'pk': ?, 'sk': ?}",
            "DELETE FROM \"Orders\" WHERE \"pk\" = ? AND \"sk\" = ? RETURNING ALL OLD *",
            "UPDATE \"Orders\" SET \"name\" = ? WHERE \"pk\" = ? AND \"sk\" = ? AND \"name\" = ?"
        ])
        #expect(result.map(\.parameters) == [["n3", "3"], ["d2", "2"], ["Bea", "p1", "7", "Ann"]])
    }
}
