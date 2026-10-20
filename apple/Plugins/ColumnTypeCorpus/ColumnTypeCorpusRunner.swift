//
//  ColumnTypeCorpusRunner.swift
//  ColumnTypeCorpus
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

struct ColumnTypeCorpusExport: Sendable {
    let formatId: String
    let optionValues: [Bool]
    let write: @Sendable (_ tables: [PluginExportTable], _ source: any PluginExportDataSource, _ destination: URL)
        async throws -> Void
}

// Takes each corpus column through what a user does with a table: open it, edit a cell, save, read it back, and
// export it as CSV, JSON and SQL. Each step goes through the driver call the host makes for it.
struct ColumnTypeCorpusRunner: Sendable {
    private typealias Rows = [Int: [PluginCellValue]]

    private struct Read {
        let columns: [String]
        let columnTypeNames: [String]
        let rows: Rows
    }

    private struct StepFailure: Error {
        let problems: [String]
    }

    static let idColumn = "id"
    static let valueColumn = "v"
    private static let pageSize = 200

    let corpus: ColumnTypeCorpus
    let driver: any PluginDatabaseDriver
    let listedTypes: [String: [String]]
    let dialect: SQLDialectDescriptor?
    let supportsCascadeDrop: Bool
    let exports: [ColumnTypeCorpusExport]
    let workDirectory: URL
    var tablePrefix = "tpc_"
    var keepTables = false
    var includes: @Sendable (ColumnTypeCorpus.Column) -> Bool = { _ in true }

    private var grammar: SQLLexicalGrammar {
        let declared = dialect?.lexicalFeatures.map { SQLLexicalGrammar(rawValue: $0.rawValue) }
        return SQLLexicalReadings.resolve(databaseTypeId: corpus.databaseTypeId, declared: declared, session: nil)
            .execution
    }

    // The kit's features are the grammar facts below bit 25, bit for bit (SQLLexicalResolver.pluginFeaturePairs).
    private var lexicalFeatures: SQLLexicalFeatures {
        SQLLexicalFeatures(rawValue: grammar.rawValue & ((1 << 25) - 1))
    }

    func run(log: @escaping @Sendable (String) -> Void) async -> ColumnTypeCorpusReport {
        var report = ColumnTypeCorpusReport(log: log)
        let uncovered = corpus.uncoveredTypes(listed: listedTypes)
        report.record(
            corpus.engine,
            "coverage",
            uncovered.isEmpty ? .passed : .failed("listed with no corpus column: \(uncovered.joined(separator: ", "))")
        )
        let selected = corpus.columns.enumerated().filter { includes($0.element) }
        guard !selected.isEmpty else {
            report.record(corpus.engine, "columns", .failed("no corpus column is selected"))
            return report
        }
        for (index, column) in selected {
            await run(column, table: "\(tablePrefix)\(index)", report: &report)
        }
        return report
    }

    // MARK: - One column

    private func run(_ column: ColumnTypeCorpus.Column, table: String, report: inout ColumnTypeCorpusReport) async {
        await dropTable(table)
        await runSteps(column, table: table, report: &report)
        if !keepTables {
            await dropTable(table)
        }
    }

    private func runSteps(
        _ column: ColumnTypeCorpus.Column,
        table: String,
        report: inout ColumnTypeCorpusReport
    ) async {
        do {
            _ = try await driver.execute(query: createStatement(table, column: column))
            report.record(column, .create, problems: [])
        } catch {
            report.record(column, .create, problems: [describe(error)])
            return
        }

        var insertProblems: [String] = []
        for (offset, value) in column.values.enumerated() {
            do {
                _ = try await driver.execute(query: insertStatement(table, id: offset + 1, valueSQL: value.sql))
            } catch {
                insertProblems.append("\(value.sql): \(describe(error))")
            }
        }
        report.record(column, .insert, problems: insertProblems)
        guard insertProblems.isEmpty else { return }

        var columnInfo: [PluginColumnInfo] = []
        do {
            columnInfo = try await driver.fetchColumns(table: table, schema: nil)
            let names = columnInfo.map(\.name)
            report.record(
                column,
                .columns,
                problems: names.contains(Self.valueColumn) ? [] : ["the column list is \(names)"]
            )
        } catch {
            report.record(column, .columns, problems: [describe(error)])
        }

        var page: Read
        do {
            page = try await browse(table, columnNames: columnInfo.map(\.name))
            report.record(column, .browse, problems: expectedCellProblems(column, in: page))
        } catch {
            report.record(column, .browse, problems: [describe(error)])
            return
        }

        if let reason = column.skip[.stream] {
            report.record(column.type, ColumnTypeCorpus.Step.stream.rawValue, .skipped(reason))
        } else {
            do {
                let streamed = try await stream(table)
                report.record(column, .stream, problems: differences(streamed, from: page, what: "the export read"))
            } catch {
                report.record(column, .stream, problems: [describe(error)])
            }
        }

        if let reason = column.skip[.edit] {
            report.record(column.type, ColumnTypeCorpus.Step.edit.rawValue, .skipped(reason))
        } else if let edit = column.edit {
            do {
                page = try await save(edit, table: table, page: page, columnInfo: columnInfo)
                report.record(column, .edit, problems: [])
            } catch {
                report.record(column, .edit, problems: [describe(error)])
                // The exports compare against what the table holds now, whatever the save did.
                if let current = try? await browse(table, columnNames: page.columns) {
                    page = current
                }
            }
        }

        let source = ColumnTypeCorpusExportSource(
            driver: driver,
            databaseTypeId: corpus.databaseTypeId,
            lexicalFeatures: lexicalFeatures,
            supportsCascadeDrop: supportsCascadeDrop
        )
        let category = corpus.category(of: column, listed: listedTypes)
        for export in exports {
            guard let step = ColumnTypeCorpus.Step(rawValue: export.formatId) else { continue }
            if let reason = column.skip[step] {
                report.record(column.type, step.rawValue, .skipped(reason))
                continue
            }
            do {
                let destination = workDirectory.appendingPathComponent("\(table).\(export.formatId)")
                defer { try? FileManager.default.removeItem(at: destination) }
                let exported = PluginExportTable(
                    name: table,
                    databaseName: "",
                    tableType: "table",
                    optionValues: export.optionValues,
                    schema: nil,
                    kind: .table
                )
                try await export.write([exported], source, destination)
                let problems: [String]
                switch step {
                case .csv: problems = try csvProblems(destination, page: page)
                case .json: problems = try jsonProblems(destination, table: table, page: page, category: category)
                case .sql: problems = try await sqlProblems(destination, table: table, page: page)
                default: problems = []
                }
                report.record(column, step, problems: problems)
            } catch {
                report.record(column, step, problems: [describe(error)])
            }
        }
    }

    // MARK: - Statements

    private func fill(_ template: String, table: String, column: ColumnTypeCorpus.Column? = nil) -> String {
        var sql = template
            .replacingOccurrences(of: "{table}", with: driver.quoteIdentifier(table))
            .replacingOccurrences(of: "{id}", with: driver.quoteIdentifier(Self.idColumn))
            .replacingOccurrences(of: "{column}", with: driver.quoteIdentifier(Self.valueColumn))
            .replacingOccurrences(of: "{tableName}", with: table)
        if let column {
            sql = sql.replacingOccurrences(of: "{type}", with: column.type)
        }
        return sql
    }

    private func createStatement(_ table: String, column: ColumnTypeCorpus.Column) -> String {
        fill(corpus.createTable, table: table, column: column)
    }

    private func dropStatement(_ table: String) -> String {
        fill(corpus.dropTable ?? "DROP TABLE IF EXISTS {table}", table: table)
    }

    private func dropTable(_ table: String) async {
        _ = try? await driver.execute(query: dropStatement(table))
    }

    private func insertStatement(_ table: String, id: Int, valueSQL: String) -> String {
        let quoted = driver.quoteIdentifier
        return "INSERT INTO \(quoted(table)) (\(quoted(Self.idColumn)), \(quoted(Self.valueColumn))) "
            + "VALUES (\(id), \(valueSQL))"
    }

    // The table tab sorted by its id column: the driver's own browse statement when it writes one, else the host's.
    private func browseStatement(_ table: String, columnNames: [String]) -> String {
        let columns = columnNames.isEmpty ? [Self.idColumn, Self.valueColumn] : columnNames
        let idIndex = columns.firstIndex(of: Self.idColumn) ?? 0
        if let sql = driver.buildBrowseQuery(
            table: table, schema: nil, sortColumns: [(columnIndex: idIndex, ascending: true)],
            columns: columns, limit: Self.pageSize, offset: 0
        ) {
            return sql
        }
        let quoted = driver.quoteIdentifier
        let pagination = dialect?.paginationStyle == .offsetFetch
            ? "OFFSET 0 ROWS FETCH NEXT \(Self.pageSize) ROWS ONLY"
            : "LIMIT \(Self.pageSize) OFFSET 0"
        return "SELECT * FROM \(quoted(table)) ORDER BY \(quoted(Self.idColumn)) ASC \(pagination)"
    }

    private func placeholder(_ position: Int) -> String {
        driver.parameterStyle == .dollar ? "$\(position)" : "?"
    }

    // SQLStatementGenerator's UPDATE for a grid edit, for a driver that leaves its statements to the host.
    private func hostUpdate(
        table: String,
        read: Read,
        original: [PluginCellValue],
        newValue: PluginCellValue,
        primaryKey: [String]
    ) -> (sql: String, parameters: [PluginCellValue]) {
        let quoted = driver.quoteIdentifier
        var parameters: [PluginCellValue] = [newValue]
        var conditions: [String] = []
        let matched = primaryKey.isEmpty ? read.columns : primaryKey
        for name in matched {
            guard let index = read.columns.firstIndex(of: name), index < original.count else { continue }
            if original[index].isNull {
                conditions.append("\(quoted(name)) IS NULL")
            } else {
                parameters.append(original[index])
                conditions.append("\(quoted(name)) = \(placeholder(parameters.count))")
            }
        }
        let sql = "UPDATE \(quoted(table)) SET \(quoted(Self.valueColumn)) = \(placeholder(1)) WHERE "
            + conditions.joined(separator: " AND ")
        return (sql, parameters)
    }

    // MARK: - Reads

    private func rows(columns: [String], values: [[PluginCellValue]]) throws -> Rows {
        guard let idIndex = columns.firstIndex(of: Self.idColumn) else {
            throw StepFailure(problems: ["no \(Self.idColumn) column in \(columns)"])
        }
        var rows: Rows = [:]
        for row in values {
            guard idIndex < row.count, let text = Self.text(of: row[idIndex]), let id = Int(text) else {
                throw StepFailure(problems: ["a row without a readable id: \(row.map(Self.text(of:)))"])
            }
            guard rows.updateValue(row, forKey: id) == nil else {
                throw StepFailure(problems: ["row \(id) is read twice"])
            }
        }
        return rows
    }

    private func browse(_ table: String, columnNames: [String]) async throws -> Read {
        let result = try await driver.executeUserQuery(
            query: browseStatement(table, columnNames: columnNames), rowCap: nil, parameters: nil
        )
        return Read(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: try rows(columns: result.columns, values: result.rows)
        )
    }

    private func stream(_ table: String) async throws -> Read {
        let read = ColumnTypeCorpusExportSource.readQuery(table: table, driver: driver)
        var header: PluginStreamHeader?
        var values: [[PluginCellValue]] = []
        for try await element in driver.streamRows(query: read.sql, context: read.context) {
            switch element {
            case .header(let streamed): header = streamed
            case .rows(let rows): values.append(contentsOf: rows)
            }
        }
        guard let header else { throw StepFailure(problems: ["no header"]) }
        return Read(
            columns: header.columns,
            columnTypeNames: header.columnTypeNames,
            rows: try rows(columns: header.columns, values: values)
        )
    }

    // MARK: - Save

    private func save(
        _ edit: ColumnTypeCorpus.Edit,
        table: String,
        page: Read,
        columnInfo: [PluginColumnInfo]
    ) async throws -> Read {
        let rowID = edit.row ?? 1
        guard let original = page.rows[rowID], let valueIndex = page.columns.firstIndex(of: Self.valueColumn) else {
            throw StepFailure(problems: ["no row \(rowID) to edit"])
        }
        let newValue: PluginCellValue
        if let hex = edit.hex {
            guard let data = Self.data(hex: hex) else { throw StepFailure(problems: ["\(hex) is not hex"]) }
            newValue = .bytes(data)
        } else if let text = edit.text {
            newValue = .text(text)
        } else {
            newValue = .null
        }

        var context = PluginRowWriteContext()
        context.serverOwnedColumns = Set(columnInfo.filter { $0.isGenerated || $0.isIdentity }.map(\.name))
        context.columnTypeNames = Dictionary(
            zip(page.columns, page.columnTypeNames), uniquingKeysWith: { first, _ in first }
        )
        let primaryKey = columnInfo.filter(\.isPrimaryKey).map(\.name)
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: valueIndex, columnName: Self.valueColumn, oldValue: original[valueIndex],
                           newValue: newValue)],
            originalRow: original
        )
        let statements: [(sql: String, parameters: [PluginCellValue])]
        if let writes = try driver.generateRowWrites(
            table: table, schema: nil, columns: page.columns, primaryKeyColumns: primaryKey, changes: [change],
            insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [], context: context
        ) {
            statements = writes.map { ($0.statement, $0.parameters) }
        } else {
            statements = [hostUpdate(
                table: table, read: page, original: original, newValue: newValue, primaryKey: primaryKey
            )]
        }

        let transactional = driver.supportsTransactions
        do {
            if transactional { try await driver.beginTransaction() }
            for statement in statements {
                if statement.parameters.isEmpty {
                    _ = try await driver.execute(query: statement.sql)
                } else {
                    _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                }
            }
            if transactional { try await driver.commitTransaction() }
        } catch {
            if transactional { try? await driver.rollbackTransaction() }
            throw StepFailure(problems: ["\(statements.map(\.sql).joined(separator: "; ")): \(describe(error))"])
        }

        if let settle = corpus.settleAfterSave {
            try await waitForZero(fill(settle, table: table))
        }
        let readBack = try await browse(table, columnNames: page.columns)
        var problems: [String] = []
        let edited = readBack.rows[rowID].flatMap { valueIndex < $0.count ? Self.text(of: $0[valueIndex]) : nil }
        if edited != edit.cell {
            problems.append("row \(rowID) reads back \(Self.show(edited)), expected \(Self.show(edit.cell))")
        }
        var untouched = page.rows
        untouched[rowID] = readBack.rows[rowID]
        problems += differences(readBack, from: Read(columns: page.columns, columnTypeNames: [], rows: untouched),
                                what: "after the save")
        guard problems.isEmpty else { throw StepFailure(problems: problems) }
        return readBack
    }

    private func waitForZero(_ query: String) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let result = try await driver.execute(query: query)
            if result.rows.first?.first.flatMap(Self.text(of:)) == "0" { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StepFailure(problems: ["\(query) did not reach 0 in 60 seconds"])
    }

    // MARK: - Checks

    private func expectedCellProblems(_ column: ColumnTypeCorpus.Column, in read: Read) -> [String] {
        guard let valueIndex = read.columns.firstIndex(of: Self.valueColumn) else {
            return ["no \(Self.valueColumn) column in \(read.columns)"]
        }
        var problems: [String] = []
        if read.rows.count != column.values.count {
            problems.append("\(read.rows.count) rows, expected \(column.values.count)")
        }
        for (offset, value) in column.values.enumerated() {
            let cell = read.rows[offset + 1].flatMap { valueIndex < $0.count ? Self.text(of: $0[valueIndex]) : nil }
            if let pattern = value.matches {
                if cell?.range(of: pattern, options: .regularExpression) == nil {
                    problems.append("\(value.sql) reads \(Self.show(cell)), expected a match for \(pattern)")
                }
            } else if cell != value.cell {
                problems.append("\(value.sql) reads \(Self.show(cell)), expected \(Self.show(value.cell))")
            }
        }
        return problems
    }

    private func differences(_ read: Read, from page: Read, what: String) -> [String] {
        guard let valueIndex = read.columns.firstIndex(of: Self.valueColumn),
              let pageIndex = page.columns.firstIndex(of: Self.valueColumn) else {
            return ["\(what) has columns \(read.columns)"]
        }
        var problems: [String] = []
        if read.rows.count != page.rows.count {
            problems.append("\(what) has \(read.rows.count) rows, the table tab \(page.rows.count)")
        }
        for (id, row) in page.rows.sorted(by: { $0.key < $1.key }) {
            let shown = pageIndex < row.count ? Self.text(of: row[pageIndex]) : nil
            let other = read.rows[id].flatMap { valueIndex < $0.count ? Self.text(of: $0[valueIndex]) : nil }
            if shown != other {
                problems.append("row \(id): \(what) reads \(Self.show(other)), the table tab \(Self.show(shown))")
            }
        }
        return problems
    }

    private func csvProblems(_ file: URL, page: Read) throws -> [String] {
        let records = CorpusCSVReader.records(try String(contentsOf: file, encoding: .utf8))
        guard let header = records.first,
              let idIndex = header.firstIndex(of: Self.idColumn),
              let valueIndex = header.firstIndex(of: Self.valueColumn),
              let pageIndex = page.columns.firstIndex(of: Self.valueColumn) else {
            return ["header \(records.first ?? [])"]
        }
        var problems: [String] = []
        var seen = Set<Int>()
        for record in records.dropFirst() {
            guard record.count > max(idIndex, valueIndex), let id = Int(record[idIndex]), let row = page.rows[id],
                  seen.insert(id).inserted else {
                problems.append("an unexpected or repeated record \(record)")
                continue
            }
            let shown = Self.text(of: row[pageIndex]) ?? ""
            let field = record[valueIndex]
            let sanitized = shown.first.map { "=+-@\t\r".contains($0) } == true && field == "'" + shown
            if field != shown, !sanitized {
                problems.append("row \(id): \(Self.show(field)), the table tab \(Self.show(shown))")
            }
        }
        problems += Self.missingRows(Set(page.rows.keys).subtracting(seen))
        return problems
    }

    private func jsonProblems(_ file: URL, table: String, page: Read, category: String?) throws -> [String] {
        let root = try CorpusJSONReader.parse(Data(contentsOf: file))
        guard case .array(let objects)? = root[table], let pageIndex = page.columns.firstIndex(of: Self.valueColumn)
        else {
            return ["no array under \(table)"]
        }
        var problems: [String] = []
        var seen = Set<Int>()
        for object in objects {
            guard let id = Self.jsonText(object[Self.idColumn]).flatMap(Int.init), let row = page.rows[id],
                  seen.insert(id).inserted else {
                problems.append("an unexpected or repeated row \(object)")
                continue
            }
            if let problem = Self.jsonProblem(object[Self.valueColumn], cell: row[pageIndex], category: category) {
                problems.append("row \(id): \(problem)")
            }
        }
        problems += Self.missingRows(Set(page.rows.keys).subtracting(seen))
        return problems
    }

    // The dump, run into the emptied table, has to put back what the table tab showed.
    private func sqlProblems(_ file: URL, table: String, page: Read) async throws -> [String] {
        let dump = try String(contentsOf: file, encoding: .utf8)
        let statements = SQLStatementScanner.locatedStatements(in: dump, grammar: grammar)
            .filter(\.hasContent)
            .map { SQLStatementSplitting.stripLeadingComments($0.sql, lexicalFeatures: lexicalFeatures) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(";") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        guard !statements.isEmpty else { return ["the dump has no statement"] }
        _ = try await driver.execute(query: fill(corpus.clearTable ?? "DELETE FROM {table}", table: table))
        for statement in statements {
            do {
                _ = try await driver.execute(query: statement)
            } catch {
                return ["replaying \(statement.prefix(200)): \(describe(error))"]
            }
        }
        let replayed = try await browse(table, columnNames: page.columns)
        return differences(replayed, from: page, what: "the replayed dump")
    }

    private static func missingRows(_ ids: Set<Int>) -> [String] {
        ids.isEmpty ? [] : ["rows \(ids.sorted()) are missing"]
    }

    // MARK: - Values

    static func text(of cell: PluginCellValue) -> String? {
        switch cell {
        case .null: nil
        case .text(let text): text
        case .bytes(let data): "0x" + data.map { String(format: "%02X", $0) }.joined()
        }
    }

    private static func show(_ text: String?) -> String {
        guard let text else { return "NULL" }
        guard text.count > 80 else { return String(reflecting: text) }
        return String(reflecting: String(text.prefix(60))) + "… (\(text.count) characters)"
    }

    static func data(hex: String) -> Data? {
        let digits = Array(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    private static func jsonText(_ value: CorpusJSONValue?) -> String? {
        switch value {
        case .string(let text)?: text
        case .number(let literal)?: literal
        default: nil
        }
    }

    private static func jsonProblem(_ value: CorpusJSONValue?, cell: PluginCellValue, category: String?) -> String? {
        switch (cell, value) {
        case (.null, nil), (.null, .null?):
            return nil
        case (.bytes(let data), .string(let text)?) where Data(base64Encoded: text) == data:
            return nil
        case (.text(let text), .string(let written)?) where written == text:
            return nil
        case (.text(let text), .number(let literal)?) where ["Integer", "Float", "Boolean"].contains(category ?? ""):
            return sameNumber(literal, text) ? nil : "the number \(literal), the table tab \(show(text))"
        case (.text(let text), .bool(let flag)?) where category == "Boolean":
            return booleanText(text) == flag ? nil : "\(flag), the table tab \(show(text))"
        default:
            return "\(value.map { "\($0)" } ?? "missing"), the table tab \(show(text(of: cell)))"
        }
    }

    private static func booleanText(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "t", "1", "yes", "on": true
        case "false", "f", "0", "no", "off": false
        default: nil
        }
    }

    // Equal when both spell the same value: 1.50 and 1.5, 1.0e-06 and -1e-6 written either way, 1e+308 and 1e308.
    private static func sameNumber(_ literal: String, _ text: String) -> Bool {
        guard let left = decimalForm(literal), let right = decimalForm(text) else { return literal == text }
        return left == right
    }

    // Sign, significant digits and the exponent of the last one, or nil for text that is not a decimal number.
    private static func decimalForm(_ number: String) -> String? {
        var rest = Substring(number)
        var negative = false
        if let sign = rest.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            rest = rest.dropFirst()
        }
        var exponent = 0
        if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(rest[rest.index(after: marker)...]) else { return nil }
            exponent = value
            rest = rest[..<marker]
        }
        let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? ""
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        guard !(whole + fraction).isEmpty, (whole + fraction).allSatisfy(\.isASCII), (whole + fraction).allSatisfy(\.isNumber)
        else { return nil }
        var digits = Substring(whole + fraction)
        exponent -= fraction.count
        while digits.count > 1, digits.first == "0" { digits = digits.dropFirst() }
        while digits.count > 1, digits.last == "0" {
            digits = digits.dropLast()
            exponent += 1
        }
        if digits == "0" { return "0" }
        return "\(negative ? "-" : "")\(digits)e\(exponent)"
    }

    private func describe(_ error: Error) -> String {
        if let failure = error as? StepFailure { return failure.problems.joined(separator: "; ") }
        let localized = (error as? LocalizedError)?.errorDescription
        return localized ?? String(describing: error)
    }
}
