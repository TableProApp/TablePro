import Foundation
import TableProPluginKit

extension DynamoDBPluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        try await runStatement(query, parameters: [], rowCap: PluginRowLimits.emergencyMax)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await runStatement(query, parameters: parameters, rowCap: PluginRowLimits.emergencyMax)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await runStatement(query, parameters: parameters ?? [], rowCap: rowCap ?? PluginRowLimits.emergencyMax)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await runStatement(query, parameters: [], rowCap: rowCap)
    }

    private func runStatement(_ text: String, parameters: [PluginCellValue], rowCap: Int) async throws -> PluginQueryResult {
        let statement = try DynamoDBStatement.parse(text)
        switch statement {
        case .browse(let request, let window):
            return try await run { session in
                try await self.readBrowse(request, window: window, rowCap: rowCap, session: session)
            }
        case .apiCall(let call, let window):
            guard parameters.isEmpty else { throw Self.parametersNeedPartiQL }
            if call.operation == .scan || call.operation == .query {
                return try await run { session in
                    try await self.readRequest(call, window: window, rowCap: rowCap, session: session)
                }
            }
            return try await run(boundedByQueryTimeout: call.operation.isRead) { session in
                try await self.callAPI(call, session: session)
            }
        case .partiQL(let statementText, let window):
            if DynamoDBPartiQL.kind(of: statementText) == .select {
                return try await run { session in
                    try await self.readPartiQL(
                        statementText, window: window, parameters: parameters, rowCap: rowCap, session: session
                    )
                }
            }
            return try await run(boundedByQueryTimeout: false) { session in
                try await self.writePartiQL(statementText, parameters: parameters, session: session)
            }
        }
    }

    static var parametersNeedPartiQL: DynamoDBError {
        .invalidStatement(String(localized: "Parameters apply only to PartiQL statements"))
    }

    // MARK: - Browse

    func readBrowse(
        _ request: DynamoDBBrowseRequest,
        window: DynamoDBReadWindow,
        rowCap: Int,
        session: Session
    ) async throws -> PluginQueryResult {
        let started = Date()
        let schema = try await tableSchema(request.table, session: session)
        guard !schema.isBeingCreated else {
            return Self.queryResult(
                items: [], schema: schema, preferredColumns: request.columns, includeAllKeys: true,
                started: started, isTruncated: false,
                statusMessage: String(localized: "DynamoDB is still creating this table. Refresh in a moment.")
            )
        }
        let plan = try DynamoDBAccessPlanner(schema: schema).plan(request, order: window.order)
        let (wanted, readLimit) = Self.readLimits(window: window, rowCap: rowCap)
        var items: [DynamoDBItem] = []
        let stats = try await readPlan(
            plan, schema: schema, offset: window.offset, limit: readLimit,
            fingerprint: fingerprint(of: .browse(request, window: window)) + plan.positionKey, session: session
        ) { item in
            items.append(item)
            return true
        }
        let ordered = order(items, by: plan.unsatisfiedOrder, isComplete: window.offset == 0 && stats.reachedEnd)
            .truncated(to: wanted)
        let isTruncated = items.count > wanted
        rememberTypes(of: ordered.items, table: schema.name, schema: schema, session: session)
        var visibleStats = stats
        visibleStats.returned = ordered.items.count
        return Self.queryResult(
            items: ordered.items,
            schema: schema,
            preferredColumns: request.columns,
            includeAllKeys: true,
            started: started,
            isTruncated: isTruncated,
            statusMessage: Self.statusMessage(
                access: plan.summary, stats: visibleStats, extra: ordered.note.map { [$0] } ?? []
            )
        )
    }

    /// Applies sort terms DynamoDB could not. Only a result held in full can be sorted: the first
    /// page of a sorted table is not the first page re-ordered.
    struct OrderedItems {
        var items: [DynamoDBItem]
        let note: String?

        func truncated(to count: Int) -> OrderedItems {
            OrderedItems(items: Array(items.prefix(max(count, 0))), note: note)
        }
    }

    /// Applies sort terms DynamoDB could not, before any row is cut: only a result held in full can
    /// be sorted, because the first page of a sorted table is not the first page re-ordered.
    func order(_ items: [DynamoDBItem], by terms: [DynamoDBOrderTerm], isComplete: Bool) -> OrderedItems {
        guard !terms.isEmpty else { return OrderedItems(items: items, note: nil) }
        guard isComplete else {
            let names = terms.map(\.attribute).joined(separator: ", ")
            return OrderedItems(items: items, note: String(format: String(
                localized: "In DynamoDB order: sorting by %@ needs the whole result, or a Query on that sort key"
            ), names))
        }
        return OrderedItems(items: DynamoDBItemTable.sorted(items, by: terms), note: nil)
    }

    /// How many rows to show and how many to read: one more than the cap, so a result that does not
    /// fit is known to be truncated.
    static func readLimits(window: DynamoDBReadWindow, rowCap: Int) -> (wanted: Int, read: Int) {
        let cap = max(rowCap, 0)
        guard let limit = window.limit else { return (cap, cap.addingReportingOverflow(1).overflow ? cap : cap + 1) }
        let clamped = max(limit, 0)
        return clamped <= cap ? (clamped, clamped) : (cap, cap + 1)
    }

    func fingerprint(of statement: DynamoDBStatement) -> String {
        switch statement {
        case .browse(let request, let window):
            let planOnly = DynamoDBBrowseRequest(
                table: request.table, filters: request.filters, matchAll: request.matchAll, columns: []
            )
            return DynamoDBStatement.browse(planOnly, window: DynamoDBReadWindow(order: window.order)).text
        case .apiCall(let call, let window):
            return DynamoDBStatement.apiCall(call, window: DynamoDBReadWindow(order: window.order)).text
        case .partiQL(let text, let window):
            return DynamoDBStatement.partiQL(text: text, window: DynamoDBReadWindow(order: window.order)).text
        }
    }

    func rememberTypes(of items: [DynamoDBItem], table: String, schema: DynamoDBTableSchema?, session: Session) {
        let observed = DynamoDBItemTable(items: items, schema: schema).observedTypes
        catalog.mergeColumnTypes(observed, for: table, in: session.scope)
    }

    // MARK: - Scan and Query requests

    func readRequest(
        _ call: DynamoDBAPICall,
        window: DynamoDBReadWindow,
        rowCap: Int,
        session: Session
    ) async throws -> PluginQueryResult {
        let started = Date()
        guard let body = call.body.objectValue, let table = body["TableName"]?.stringValue else {
            throw DynamoDBError.invalidStatement(String(localized: "The request needs a TableName"))
        }
        if body["Select"]?.stringValue == "COUNT" {
            return try await countRequest(call.operation, body: body, session: session, started: started)
        }
        let schema = try? await tableSchema(table, session: session)
        let plan = DynamoDBReadPlan(
            table: table,
            access: call.operation == .query ? .query : .scan,
            indexName: body["IndexName"]?.stringValue,
            requests: [body],
            clientPredicates: [],
            clientMatchAll: true,
            unsatisfiedOrder: window.order
        )
        let (wanted, readLimit) = Self.readLimits(window: window, rowCap: rowCap)
        var items: [DynamoDBItem] = []
        let stats = try await readPlan(
            plan, schema: schema, offset: window.offset, limit: readLimit,
            fingerprint: fingerprint(of: .apiCall(call, window: window)), session: session
        ) { item in
            items.append(item)
            return true
        }
        let ordered = order(items, by: window.order, isComplete: window.offset == 0 && stats.reachedEnd)
            .truncated(to: wanted)
        let isTruncated = items.count > wanted
        var visibleStats = stats
        visibleStats.returned = ordered.items.count
        return Self.queryResult(
            items: ordered.items, schema: schema, preferredColumns: [], includeAllKeys: false,
            started: started, isTruncated: isTruncated,
            statusMessage: Self.statusMessage(
                access: call.operation.rawValue, stats: visibleStats, extra: ordered.note.map { [$0] } ?? []
            )
        )
    }

    private func countRequest(
        _ operation: DynamoDBOperation,
        body: [String: DynamoDBJSON],
        session: Session,
        started: Date
    ) async throws -> PluginQueryResult {
        var total = 0
        var scanned = 0
        var startKey: DynamoDBJSON?
        repeat {
            try session.checkDeadline()
            var page = body
            if let startKey { page["ExclusiveStartKey"] = startKey }
            let response = try await session.client.send(operation, page)
            total += response["Count"]?.intValue ?? 0
            scanned += response["ScannedCount"]?.intValue ?? 0
            startKey = response["LastEvaluatedKey"]
        } while startKey != nil
        return PluginQueryResult(
            columns: ["Count", "ScannedCount"],
            columnTypeNames: ["Number", "Number"],
            rows: [[.text(String(total)), .text(String(scanned))]],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: Date().timeIntervalSince(started))
        )
    }

    // MARK: - PartiQL reads

    func readPartiQL(
        _ text: String,
        window: DynamoDBReadWindow,
        parameters: [PluginCellValue],
        rowCap: Int,
        session: Session
    ) async throws -> PluginQueryResult {
        let started = Date()
        let target = DynamoDBPartiQL.target(of: text)
        let schema = await target.asyncMap { try? await tableSchema($0.table, session: session) } ?? nil
        var statement = text
        var clientOrder = window.order
        if let serverOrder = Self.serverOrder(for: text, target: target, schema: schema, order: window.order) {
            statement += "\n" + serverOrder
            clientOrder = []
        }

        var body: [String: DynamoDBJSON] = [
            "Statement": .string(statement),
            "ReturnConsumedCapacity": .string("TOTAL")
        ]
        if !parameters.isEmpty {
            let binder = DynamoDBParameterBinder(
                schema: schema,
                observedTypes: target.map { catalog.columnTypes(for: $0.table, in: session.scope) } ?? [:],
                currentItem: nil
            )
            let bound = try binder.bind(parameters, roles: DynamoDBPartiQL.parameterRoles(in: text))
            body["Parameters"] = .array(bound.map(\.wireJSON))
        }

        let (wanted, readLimit) = Self.readLimits(window: window, rowCap: rowCap)
        var items: [DynamoDBItem] = []
        var stats = DynamoDBReadStats()
        var skipped = 0
        var nextToken: String?
        readLoop: while readLimit > 0 {
            try session.checkDeadline()
            var page = body
            if let nextToken { page["NextToken"] = .string(nextToken) }
            let (remaining, overflowed) = max(window.offset - skipped, 0).addingReportingOverflow(readLimit - items.count)
            page["Limit"] = .number(String(overflowed ? 1_000 : min(max(remaining, 1), 1_000)))
            let response = try await session.client.send(.executeStatement, page)
            let pageItems = try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
            let followingToken = response["NextToken"]?.stringValue
            stats.scanned += pageItems.count
            if let units = Self.readUnits(in: response) {
                stats.readUnits += units
                stats.reportedReadUnits = true
            }
            for (position, item) in pageItems.enumerated() {
                if skipped < window.offset {
                    skipped += 1
                    continue
                }
                items.append(item)
                if items.count >= readLimit {
                    stats.reachedEnd = followingToken == nil && position == pageItems.count - 1
                    break readLoop
                }
            }
            guard let followingToken else {
                stats.reachedEnd = true
                break
            }
            nextToken = followingToken
        }
        let ordered = order(items, by: clientOrder, isComplete: window.offset == 0 && stats.reachedEnd)
            .truncated(to: wanted)
        let isTruncated = items.count > wanted
        stats.returned = ordered.items.count
        stats.scanned = stats.returned
        if let target {
            rememberTypes(of: ordered.items, table: target.table, schema: schema, session: session)
        }
        let readsWholeTable = target?.index == nil && schema.map { schema in
            !schema.keys.partition.allSatisfy { DynamoDBPartiQL.whereFixes($0, in: text) }
        } == true
        let scanNote = readsWholeTable ? [String(localized: "This SELECT reads the whole table")] : []
        return Self.queryResult(
            items: ordered.items, schema: schema, preferredColumns: [], includeAllKeys: false,
            started: started, isTruncated: isTruncated,
            statusMessage: Self.statusMessage(
                access: nil, stats: stats, extra: scanNote + (ordered.note.map { [$0] } ?? [])
            )
        )
    }

    /// The ORDER BY DynamoDB can run itself: one term naming the single sort key of the table or of
    /// the index the statement reads, with every partition key attribute fixed by `=`.
    static func serverOrder(
        for text: String,
        target: (table: String, index: String?)?,
        schema: DynamoDBTableSchema?,
        order: [DynamoDBOrderTerm]
    ) -> String? {
        guard let schema, let target, order.count == 1 else { return nil }
        let keys: DynamoDBKeySchema
        if let indexName = target.index {
            guard let index = schema.index(named: indexName) else { return nil }
            keys = index.keys
        } else {
            keys = schema.keys
        }
        guard keys.sort.count == 1, order[0].attribute == keys.sort[0],
              keys.partition.allSatisfy({ DynamoDBPartiQL.whereFixes($0, in: text, acceptsIn: false) })
        else { return nil }
        return "ORDER BY \(DynamoDBStatement.quote(keys.sort[0]))\(order[0].descending ? " DESC" : " ASC")"
    }

    // MARK: - Streaming

    /// Streams every item a read returns, for an export, a copy or a compare.
    ///
    /// A stream states its columns once, before its first row, and a DynamoDB item may carry an
    /// attribute no earlier item had. The items are therefore written to a temporary file while the
    /// union of their attributes is collected, and the rows are sent once the read has finished, so
    /// an attribute first seen on the last page still gets its column.
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    try await self.run { session in
                        try await self.spool(query, session: session, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func spool(
        _ text: String,
        session: Session,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let statement = try DynamoDBStatement.parse(text)
        let source: SpoolSource
        do {
            source = try await spoolSource(for: statement, session: session)
        } catch DynamoDBError.invalidStatement(let message) where message == Self.notAReadMarker {
            let result = try await runStatement(text, parameters: [], rowCap: PluginRowLimits.emergencyMax)
            continuation.yield(.header(PluginStreamHeader(columns: result.columns, columnTypeNames: result.columnTypeNames)))
            if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
            return
        }

        let spoolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TablePro-DynamoDB-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil) else {
            throw DynamoDBError.transport(String(localized: "Could not create a temporary file for the export"))
        }
        defer { try? FileManager.default.removeItem(at: spoolURL) }

        let sortsLocally = !source.clientOrder.isEmpty
        let readOffset = sortsLocally ? 0 : source.window.offset
        let readLimit = sortsLocally ? Int.max : max(source.window.limit ?? Int.max, 0)
        var collector = SpoolCollector(handle: try FileHandle(forWritingTo: spoolURL))
        try await source.read(readOffset, readLimit) { item in
            try collector.add(item)
            return true
        }
        try collector.handle.close()

        let columns = collector.columns(preferred: source.preferredColumns, schema: source.schema)
        continuation.yield(.header(PluginStreamHeader(columns: columns, columnTypeNames: collector.typeNames(for: columns, schema: source.schema))))

        if sortsLocally {
            var items: [DynamoDBItem] = []
            var lines = try SpoolLines(url: spoolURL)
            defer { lines.close() }
            while let line = try lines.next() {
                try Task.checkCancellation()
                items.append(try DynamoDBItem(wireItem: DynamoDBJSON.parse(line)))
            }
            let sorted = DynamoDBItemTable.sorted(items, by: source.clientOrder)
            let end = source.window.limit.map { limit in
                let (sum, overflowed) = source.window.offset.addingReportingOverflow(max(limit, 0))
                return overflowed ? sorted.count : min(sorted.count, sum)
            } ?? sorted.count
            let slice = source.window.offset < end ? Array(sorted[source.window.offset..<end]) : []
            for start in stride(from: 0, to: slice.count, by: 1_000) {
                let batch = slice[start..<min(start + 1_000, slice.count)]
                continuation.yield(.rows(batch.map { item in columns.map { DynamoDBCellCodec.cell(for: item[$0]) } }))
            }
            return
        }

        var batch: [PluginRow] = []
        batch.reserveCapacity(1_000)
        var lines = try SpoolLines(url: spoolURL)
        defer { lines.close() }
        while let line = try lines.next() {
            try Task.checkCancellation()
            let item = try DynamoDBItem(wireItem: DynamoDBJSON.parse(line))
            batch.append(columns.map { DynamoDBCellCodec.cell(for: item[$0]) })
            if batch.count == 1_000 {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { continuation.yield(.rows(batch)) }
    }

    private static let notAReadMarker = "\u{0}not-a-read"

    /// A read a stream can spool: how to read it from an offset, which sort terms DynamoDB could
    /// not apply, and the columns and schema that lay its rows out.
    private struct SpoolSource {
        let window: DynamoDBReadWindow
        let clientOrder: [DynamoDBOrderTerm]
        let schema: DynamoDBTableSchema?
        let preferredColumns: [String]
        let read: (_ offset: Int, _ limit: Int, _ sink: (DynamoDBItem) throws -> Bool) async throws -> Void
    }

    private func spoolSource(for statement: DynamoDBStatement, session: Session) async throws -> SpoolSource {
        switch statement {
        case .browse(let request, let window):
            let schema = try await tableSchema(request.table, session: session)
            let plan = try DynamoDBAccessPlanner(schema: schema).plan(request, order: window.order)
            let fingerprint = fingerprint(of: statement) + plan.positionKey
            return SpoolSource(
                window: window, clientOrder: plan.unsatisfiedOrder, schema: schema, preferredColumns: request.columns
            ) { offset, limit, sink in
                _ = try await self.readPlan(
                    plan, schema: schema, offset: offset, limit: limit, fingerprint: fingerprint, session: session, sink: sink
                )
            }
        case .apiCall(let call, let window) where call.operation == .scan || call.operation == .query:
            guard let body = call.body.objectValue, let table = body["TableName"]?.stringValue else {
                throw DynamoDBError.invalidStatement(String(localized: "The request needs a TableName"))
            }
            let schema = try? await tableSchema(table, session: session)
            let plan = DynamoDBReadPlan(
                table: table, access: call.operation == .query ? .query : .scan,
                indexName: body["IndexName"]?.stringValue, requests: [body],
                clientPredicates: [], clientMatchAll: true, unsatisfiedOrder: window.order
            )
            let fingerprint = fingerprint(of: statement)
            return SpoolSource(window: window, clientOrder: window.order, schema: schema, preferredColumns: []) { offset, limit, sink in
                _ = try await self.readPlan(
                    plan, schema: schema, offset: offset, limit: limit, fingerprint: fingerprint, session: session, sink: sink
                )
            }
        case .partiQL(let statementText, let window) where DynamoDBPartiQL.kind(of: statementText) == .select:
            let target = DynamoDBPartiQL.target(of: statementText)
            let schema = await target.asyncMap { try? await tableSchema($0.table, session: session) } ?? nil
            let serverOrder = Self.serverOrder(for: statementText, target: target, schema: schema, order: window.order)
            let sent = serverOrder.map { statementText + "\n" + $0 } ?? statementText
            return SpoolSource(
                window: window, clientOrder: serverOrder == nil ? window.order : [], schema: schema, preferredColumns: []
            ) { offset, limit, sink in
                try await self.readPartiQLPages(sent, offset: offset, limit: limit, session: session, sink: sink)
            }
        default:
            throw DynamoDBError.invalidStatement(Self.notAReadMarker)
        }
    }

    private func readPartiQLPages(
        _ statement: String,
        offset: Int,
        limit: Int,
        session: Session,
        sink: (DynamoDBItem) throws -> Bool
    ) async throws {
        var skipped = 0
        var sent = 0
        var nextToken: String?
        repeat {
            try session.checkDeadline()
            var body: [String: DynamoDBJSON] = ["Statement": .string(statement)]
            if let nextToken { body["NextToken"] = .string(nextToken) }
            let response = try await session.client.send(.executeStatement, body)
            for itemJSON in response["Items"]?.arrayValue ?? [] {
                if skipped < offset {
                    skipped += 1
                    continue
                }
                guard sent < limit, try sink(try DynamoDBItem(wireItem: itemJSON)) else { return }
                sent += 1
            }
            nextToken = sent < limit ? response["NextToken"]?.stringValue : nil
        } while nextToken != nil
    }
}

/// Reads the spool file back one line at a time with plain reads.
///
/// `URL.lines` would read it through `FileHandle.AsyncBytes`, and Foundation serves every AsyncBytes reader in the
/// process from one serial queue. A reader blocked on a pipe that stays quiet, such as a language server's output,
/// holds that queue, and the export then waits for it.
private struct SpoolLines {
    private static let chunkSize = 1 << 20

    private let handle: FileHandle
    private var buffer = Data()
    private var start = 0
    private var reachedEnd = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    mutating func next() throws -> Data? {
        while true {
            if let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[start..<newline]
                start = newline + 1
                return Data(line)
            }
            if reachedEnd {
                guard start < buffer.count else { return nil }
                let rest = Data(buffer[start...])
                start = buffer.count
                return rest
            }
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            buffer = Data(buffer[start...]) + chunk
            start = 0
            reachedEnd = chunk.isEmpty
        }
    }

    func close() {
        try? handle.close()
    }
}

/// Writes streamed items to the spool file and tallies their attributes and types as it goes.
private struct SpoolCollector {
    let handle: FileHandle
    private(set) var attributes = Set<String>()
    private var typeCounts: [String: [DynamoDBAttributeType: Int]] = [:]

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func add(_ item: DynamoDBItem) throws {
        try handle.write(contentsOf: Data((item.wireJSON.serialized() + "\n").utf8))
        for (name, value) in item {
            attributes.insert(name)
            guard value != .null else { continue }
            typeCounts[name, default: [:]][value.type, default: 0] += 1
        }
    }

    func columns(preferred: [String], schema: DynamoDBTableSchema?) -> [String] {
        var columns = preferred
        for name in schema?.keys.attributes ?? [] where !columns.contains(name) && attributes.contains(name) {
            columns.append(name)
        }
        return columns + attributes.subtracting(columns).sorted()
    }

    func typeNames(for columns: [String], schema: DynamoDBTableSchema?) -> [String] {
        columns.map { column in
            if schema?.keys.attributes.contains(column) == true, let keyType = schema?.keyType(of: column) {
                return keyType.displayName
            }
            let counts = typeCounts[column] ?? [:]
            return counts.max { $0.value < $1.value }?.key.displayName ?? DynamoDBAttributeType.string.displayName
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
