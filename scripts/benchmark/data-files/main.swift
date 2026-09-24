import Foundation
import TableProTabular
import TableProTabularIO

@main
enum DataFilesBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            FileHandle.standardError.write(Data("usage: data-files-benchmark <file.csv>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        let dialect = bytes.withUnsafeBytes { raw -> DelimitedDialect in
            let buffer = raw.bindMemory(to: UInt8.self)
            let sniff = DelimitedDialectDetector.sniffEncoding(buffer)
            return DelimitedDialectDetector.detect(
                buffer,
                contentStart: sniff.byteOrderMarkLength,
                encoding: sniff.encoding,
                hasByteOrderMark: sniff.hasByteOrderMark,
                fileExtension: url.pathExtension
            )
        }
        print("file \(url.lastPathComponent) \(bytes.count) bytes, cores \(ProcessInfo.processInfo.activeProcessorCount)")

        let source = try await measure("open (index + field count)") {
            try await DelimitedSourceBuilder.build(bytes: bytes, dialect: dialect, byteEncoding: .utf8, contentStart: 0)
        }
        let table = TabularTable(source: source, usesFirstRowAsHeader: dialect.hasHeaderRow)
        print("rows \(table.rowCount) columns \(table.columnCount)")
        let ids = table.columnIDs

        let contains = TabularRowPredicate.cell(TabularCellPredicate(
            column: ids[1], comparison: .contains, valueKind: .text, operand: TabularOperand(text: "smith"), isCaseSensitive: false
        ))
        let containsRows = try await measure("filter name contains smith") {
            try await TabularScanEngine.matchingRows(in: table, matcher: TabularRowMatcher(predicate: contains))
        }
        print("  matches \(containsRows.count)")

        let lastColumn = TabularRowPredicate.cell(TabularCellPredicate(
            column: ids[ids.count - 1], comparison: .contains, valueKind: .text, operand: TabularOperand(text: "refund"), isCaseSensitive: false
        ))
        _ = try await measure("filter last column contains refund") {
            try await TabularScanEngine.matchingRows(in: table, matcher: TabularRowMatcher(predicate: lastColumn))
        }

        let typed = TabularRowPredicate.cell(TabularCellPredicate(
            column: ids[3], comparison: .greaterThan, valueKind: .numeric,
            operand: TabularOperand(text: "50000", number: 50_000), isCaseSensitive: false
        ))
        _ = try await measure("filter amount > 50000") {
            try await TabularScanEngine.matchingRows(in: table, matcher: TabularRowMatcher(predicate: typed))
        }

        let search = TabularRowPredicate.search(TabularSearch(text: "hanoi", columns: ids))
        _ = try await measure("search all columns for hanoi") {
            try await TabularScanEngine.matchingRows(in: table, matcher: TabularRowMatcher(predicate: search))
        }

        let find = TabularFindQuery(
            text: "refund",
            matchesCase: false,
            matchesWholeWords: false,
            isRegularExpression: false,
            columns: ids
        )
        let found = try await measure("find all refund in every column") {
            try await TabularFinder.findAll(find, keys: table.rowOrder.keys, in: table)
        }
        print("  matches \(found.count)")

        _ = try await measure("statistics for amount") {
            try await TabularColumnStatistics.summarize(column: ids[3], kind: .decimal, keys: table.rowOrder.keys, in: table)
        }

        _ = try await measure("sort amount (numeric)") {
            try await TabularSorter.sortedKeys(table.rowOrder.keys, in: table, by: [TabularSortKey(column: ids[3], ascending: true, numeric: true)])
        }
        _ = try await measure("sort name (natural text)") {
            try await TabularSorter.sortedKeys(table.rowOrder.keys, in: table, by: [TabularSortKey(column: ids[1], ascending: true, numeric: false)])
        }
    }

    static func measure<Result>(_ label: String, _ work: () async throws -> Result) async rethrows -> Result {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock()
        let result = try await work()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1_000
        print(String(format: "%-34@ wall %8.1f ms   cpu %8.1f ms", label as NSString, wall, cpu))
        return result
    }
}
