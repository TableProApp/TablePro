import Foundation

// A grid page or export read as its body arrives. Each batch holds the rows the collected read gives for the same bytes,
// under one header that the measurement's schema types, as `typed(by:)` types the collected table.
public struct InfluxGridStream {
    public enum Body: Sendable, Equatable {
        // 3.x SQL and InfluxQL: CSV, with the header record on the first record batch only.
        case csv
        // 2.x InfluxQL with `chunked=true`: one JSON object per line, each in the v1 shape.
        case influxQLChunks
    }

    static let batchRows = 5_000
    // A wide header shrinks the batch, so one holds about a million cells at any width.
    static let batchCells = 1 << 20

    private let body: Body
    private let schema: [InfluxColumn]
    private let emptyResult: InfluxResultTable
    private var csv = InfluxCSV.Reader()
    private var lines = InfluxJSONLines()
    private var layout: InfluxResponseDecoder.V3Layout?
    private var header: InfluxResultTable?
    private var pending: [[String?]] = []
    private var bytesRead = 0
    private var rowsRead = 0

    public init(body: Body, grid: InfluxGridQuery, schema: [InfluxColumn]) {
        self.body = body
        self.schema = schema
        emptyResult = grid.emptyResult(schema: schema)
    }

    // Every batch carries the same columns and types, and the first one's are the stream's header.
    public mutating func consume(_ chunk: Data) throws -> [InfluxResultTable] {
        switch body {
        case .csv:
            bytesRead += chunk.count
            csv.read(chunk)
            return try csvBatches(csv.drain())
        case .influxQLChunks:
            var batches: [InfluxResultTable] = []
            for line in lines.consume(chunk) {
                if let batch = try influxQLBatch(line) { batches.append(batch) }
            }
            return batches
        }
    }

    // What is left once the body ends. A stream that has sent nothing gets its header here: from the CSV header record,
    // or from the schema when the body named no columns.
    public mutating func finish() throws -> [InfluxResultTable] {
        var batches: [InfluxResultTable] = []
        switch body {
        case .csv:
            batches = try csvBatches(csv.finish())
            if let layout, !pending.isEmpty || header == nil {
                batches.append(batch(pending, layout: layout))
                pending = []
            }
        case .influxQLChunks:
            if let line = lines.finish(), let batch = try influxQLBatch(line) {
                batches.append(batch)
            }
        }
        if header == nil {
            batches.append(fixedHeader(emptyResult))
        }
        return batches
    }

    private mutating func csvBatches(_ records: [[String]]) throws -> [InfluxResultTable] {
        var records = records[...]
        if layout == nil, let columns = records.popFirst() {
            layout = InfluxResponseDecoder.V3Layout(columns: columns)
        }
        guard let layout, !records.isEmpty else { return [] }
        rowsRead += records.count
        try InfluxResponseDecoder.CellBudget.perByte(bytes: bytesRead).check(rows: rowsRead, columns: layout.columns.count)
        let size = max(1, min(Self.batchRows, Self.batchCells / max(layout.columns.count, 1)))
        var batches: [InfluxResultTable] = []
        for record in records {
            pending.append(layout.row(record))
            if pending.count >= size {
                batches.append(batch(pending, layout: layout))
                pending.removeAll(keepingCapacity: true)
            }
        }
        return batches
    }

    // The first batch fixes the header. A column the schema lacks is typed from that batch's values, where the collected
    // read infers it from every row.
    private mutating func batch(_ rows: [[String?]], layout: InfluxResponseDecoder.V3Layout) -> InfluxResultTable {
        let header = self.header ?? fixedHeader(layout.table(rows).typed(by: schema))
        return InfluxResultTable(columns: header.columns, typeNames: header.typeNames, rows: rows)
    }

    private mutating func influxQLBatch(_ line: Data) throws -> InfluxResultTable? {
        let table = try InfluxResponseDecoder.decodeV1JSON(line)
        guard !table.columns.isEmpty else { return nil }
        guard let header else {
            let typed = table.typed(by: schema)
            _ = fixedHeader(typed)
            return typed
        }
        if table.columns == header.columns {
            return InfluxResultTable(columns: header.columns, typeNames: header.typeNames, rows: table.rows)
        }
        let position = Dictionary(header.columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = try table.columns.map { column -> Int in
            guard let index = position[column] else {
                throw InfluxError.malformedResponse(
                    String(format: String(localized: "column %@ first appears in a later chunk"), column)
                )
            }
            return index
        }
        let rows = table.rows.map { row -> [String?] in
            var mapped = [String?](repeating: nil, count: header.columns.count)
            for (index, target) in targets.enumerated() where index < row.count {
                mapped[target] = row[index]
            }
            return mapped
        }
        return InfluxResultTable(columns: header.columns, typeNames: header.typeNames, rows: rows)
    }

    private mutating func fixedHeader(_ table: InfluxResultTable) -> InfluxResultTable {
        if let header { return header }
        let fixed = InfluxResultTable(columns: table.columns, typeNames: table.typeNames, rows: [])
        header = fixed
        return fixed
    }
}

// The lines of a body that arrives in pieces, each line whole however the pieces split it.
struct InfluxJSONLines {
    private var partial = Data()

    mutating func consume(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while let end = chunk[start...].firstIndex(of: Self.lineFeed) {
            var line = Data()
            swap(&line, &partial)
            line.append(chunk[start ..< end])
            if !Self.isBlank(line) { lines.append(line) }
            start = chunk.index(after: end)
        }
        partial.append(chunk[start...])
        return lines
    }

    mutating func finish() -> Data? {
        var line = Data()
        swap(&line, &partial)
        return Self.isBlank(line) ? nil : line
    }

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }

    private static let lineFeed = UInt8(ascii: "\n")
}
