import Foundation
import TableProPluginKit

struct DynamoDBReadStats: Sendable, Equatable {
    var returned = 0
    var scanned = 0
    var readUnits: Double = 0
    var reportedReadUnits = false
    var reachedEnd = false
}

extension DynamoDBPluginDriver {
    /// Reads the items of `plan` from match number `offset`, up to `limit` of them, handing each to
    /// `sink`. The sink returns false to stop early.
    ///
    /// DynamoDB applies `Limit` before a FilterExpression, so an empty page with a
    /// `LastEvaluatedKey` is not the end: the reader keeps reading until it has the items it was
    /// asked for or DynamoDB has nothing left. Every page boundary it passes is remembered as the
    /// key of the item before it, so the next page starts there instead of from the first item.
    func readPlan(
        _ plan: DynamoDBReadPlan,
        schema: DynamoDBTableSchema?,
        offset: Int,
        limit: Int,
        fingerprint: String,
        session: Session,
        sink: (DynamoDBItem) throws -> Bool
    ) async throws -> DynamoDBReadStats {
        var stats = DynamoDBReadStats()
        guard plan.access != .nothing, limit > 0 else {
            stats.reachedEnd = true
            return stats
        }
        let index = plan.indexName.flatMap { schema?.index(named: $0) }
        var point = DynamoDBResumePoint.start
        var matched = 0
        if offset > 0, let cached = catalog.nearestResumePoint(
            table: plan.table, fingerprint: fingerprint, atOrBefore: offset, in: session.scope
        ) {
            point = cached.point
            matched = cached.offset
        }
        let pageSize = max(limit, 1)

        while point.requestIndex < plan.requests.count {
            try session.checkDeadline()
            var body = plan.requests[point.requestIndex]
            if let startKey = point.startKey {
                body["ExclusiveStartKey"] = startKey.wireJSON
            }
            if plan.access != .batchGet {
                body["ReturnConsumedCapacity"] = .string("TOTAL")
                if !plan.hasFilters, body["Limit"] == nil {
                    let (wanted, overflowed) = max(offset - matched, 0).addingReportingOverflow(limit - stats.returned)
                    body["Limit"] = .number(String(overflowed ? 1_000 : min(max(wanted, 1), 1_000)))
                }
            }
            let page = try await fetchPage(plan: plan, body: body, session: session)
            stats.scanned += page.scanned
            stats.readUnits += page.readUnits
            stats.reportedReadUnits = stats.reportedReadUnits || page.reportedReadUnits

            for (position, item) in page.items.enumerated() where position >= point.skip {
                guard plan.clientMatches(item) else { continue }
                let isLastOfResponse = position == page.items.count - 1
                if matched >= offset {
                    guard try sink(item) else { return stats }
                    stats.returned += 1
                }
                matched += 1
                let next = resumePoint(
                    after: item, position: position, isLastOfResponse: isLastOfResponse,
                    page: page, plan: plan, point: point, schema: schema, index: index
                )
                if let next, matched % pageSize == 0 {
                    catalog.storeResumePoint(
                        next, table: plan.table, fingerprint: fingerprint, offset: matched, in: session.scope
                    )
                }
                if stats.returned >= limit {
                    stats.reachedEnd = isLastOfResponse
                        && page.lastEvaluatedKey == nil
                        && point.requestIndex == plan.requests.count - 1
                    return stats
                }
            }
            if let lastKey = page.lastEvaluatedKey {
                point = DynamoDBResumePoint(requestIndex: point.requestIndex, startKey: lastKey, skip: 0)
            } else {
                point = DynamoDBResumePoint(requestIndex: point.requestIndex + 1, startKey: nil, skip: 0)
            }
        }
        stats.reachedEnd = true
        return stats
    }

    private func resumePoint(
        after item: DynamoDBItem,
        position: Int,
        isLastOfResponse: Bool,
        page: DynamoDBPage,
        plan: DynamoDBReadPlan,
        point: DynamoDBResumePoint,
        schema: DynamoDBTableSchema?,
        index: DynamoDBIndex?
    ) -> DynamoDBResumePoint? {
        if plan.access == .batchGet {
            guard isLastOfResponse else {
                return DynamoDBResumePoint(requestIndex: point.requestIndex, startKey: nil, skip: position + 1)
            }
            return DynamoDBResumePoint(requestIndex: point.requestIndex + 1, startKey: nil, skip: 0)
        }
        if isLastOfResponse, page.lastEvaluatedKey == nil {
            return DynamoDBResumePoint(requestIndex: point.requestIndex + 1, startKey: nil, skip: 0)
        }
        guard let key = schema?.startKey(for: item, index: index) else { return nil }
        return DynamoDBResumePoint(requestIndex: point.requestIndex, startKey: key, skip: 0)
    }

    struct DynamoDBPage {
        let items: [DynamoDBItem]
        let lastEvaluatedKey: DynamoDBItem?
        let scanned: Int
        let readUnits: Double
        let reportedReadUnits: Bool
    }

    private func fetchPage(plan: DynamoDBReadPlan, body: [String: DynamoDBJSON], session: Session) async throws -> DynamoDBPage {
        switch plan.access {
        case .batchGet:
            let items = try await batchGet(body: body, table: plan.table, session: session)
            return DynamoDBPage(items: items, lastEvaluatedKey: nil, scanned: items.count, readUnits: 0, reportedReadUnits: false)
        case .query, .scan, .nothing:
            let operation: DynamoDBOperation = plan.access == .query ? .query : .scan
            let response = try await session.client.send(operation, body)
            let items = try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
            let lastKey = try response["LastEvaluatedKey"].map(DynamoDBItem.init(wireItem:))
            let capacity = Self.readUnits(in: response)
            return DynamoDBPage(
                items: items,
                lastEvaluatedKey: lastKey,
                scanned: response["ScannedCount"]?.intValue ?? items.count,
                readUnits: capacity ?? 0,
                reportedReadUnits: capacity != nil
            )
        }
    }

    /// BatchGetItem returns what it could read and names the rest in `UnprocessedKeys`, which are
    /// sent again until none are left. Items come back in no order, so they are put back in the
    /// order their keys were asked for.
    func batchGet(body: [String: DynamoDBJSON], table: String, session: Session) async throws -> [DynamoDBItem] {
        var pending: DynamoDBJSON? = body["RequestItems"]
        var collected: [DynamoDBItem] = []
        var attempt = 0
        while let requestItems = pending, requestItems.objectValue?.isEmpty == false {
            try session.checkDeadline()
            let response = try await session.client.send(.batchGetItem, ["RequestItems": requestItems])
            for (_, items) in response["Responses"]?.objectValue ?? [:] {
                collected += try (items.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
            }
            pending = response["UnprocessedKeys"]
            guard pending?.objectValue?.isEmpty == false else { break }
            attempt += 1
            guard attempt < 10 else {
                let requested = (body["RequestItems"]?.objectValue ?? [:]).values.reduce(0) {
                    $0 + ($1["Keys"]?.arrayValue?.count ?? 0)
                }
                throw DynamoDBError.partialBatch(
                    applied: collected.count, total: requested,
                    failures: [String(localized: "DynamoDB left some keys unread after 10 attempts")]
                )
            }
            try await session.client.backOff(afterAttempt: attempt)
        }
        let requested = body["RequestItems"]?[table]?["Keys"]?.arrayValue ?? []
        let order = try requested.map(DynamoDBItem.init(wireItem:))
        return collected.sorted { lhs, rhs in
            let left = order.firstIndex { key in key.allSatisfy { lhs[$0.key] == $0.value } } ?? Int.max
            let right = order.firstIndex { key in key.allSatisfy { rhs[$0.key] == $0.value } } ?? Int.max
            return left < right
        }
    }

    static func readUnits(in response: DynamoDBJSON) -> Double? {
        if let single = response["ConsumedCapacity"]?["CapacityUnits"]?.doubleValue {
            return single
        }
        guard let list = response["ConsumedCapacity"]?.arrayValue, !list.isEmpty else { return nil }
        return list.compactMap { $0["CapacityUnits"]?.doubleValue }.reduce(0, +)
    }

    // MARK: - Results

    static func statusMessage(
        access: String?,
        stats: DynamoDBReadStats,
        extra: [String] = []
    ) -> String {
        var parts: [String] = []
        if let access { parts.append(access) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        let returned = formatter.string(from: NSNumber(value: stats.returned)) ?? "\(stats.returned)"
        let scanned = formatter.string(from: NSNumber(value: stats.scanned)) ?? "\(stats.scanned)"
        parts.append(String(format: String(localized: "%@ returned"), returned))
        if stats.scanned != stats.returned {
            parts.append(String(format: String(localized: "%@ read"), scanned))
        }
        if stats.reportedReadUnits {
            let units = formatter.string(from: NSNumber(value: stats.readUnits)) ?? "\(stats.readUnits)"
            parts.append(String(format: String(localized: "%@ RCU"), units))
        }
        return (parts + extra).joined(separator: " · ")
    }

    static func queryResult(
        items: [DynamoDBItem],
        schema: DynamoDBTableSchema?,
        preferredColumns: [String],
        includeAllKeys: Bool,
        started: Date,
        isTruncated: Bool,
        statusMessage: String?,
        rowsAffected: Int = 0
    ) -> PluginQueryResult {
        let table = DynamoDBItemTable(
            items: items,
            schema: schema,
            preferredColumns: preferredColumns,
            includeAllKeys: includeAllKeys
        )
        guard !table.columns.isEmpty else {
            return PluginQueryResult(
                columns: [], columnTypeNames: [], rows: [], rowsAffected: rowsAffected,
                timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
                isTruncated: isTruncated, statusMessage: statusMessage
            )
        }
        return PluginQueryResult(
            columns: table.columns,
            columnTypeNames: table.typeNames,
            rows: table.rows,
            rowsAffected: rowsAffected,
            timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: table.columnMeta(schema: schema)
        )
    }

    static func messageResult(_ message: String, started: Date, rowsAffected: Int = 0) -> PluginQueryResult {
        PluginQueryResult(
            columns: [], columnTypeNames: [], rows: [], rowsAffected: rowsAffected,
            timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
            statusMessage: message
        )
    }

    /// A response with no items, shown as its JSON in one cell the JSON viewer opens.
    static func responseResult(_ response: DynamoDBJSON, started: Date, statusMessage: String?) -> PluginQueryResult {
        let column = PluginColumnInfo(
            name: "Response", dataType: "JSON", isNullable: true, isPrimaryKey: false, defaultValue: nil,
            extra: nil, charset: nil, collation: nil, comment: nil, identityKind: nil, isGenerated: false,
            allowedValues: nil, generationExpression: nil, generationKind: nil, ddlSpelling: nil,
            ddlDefault: nil, ddlGenerationExpression: nil, ddlCollation: nil, classificationTypeName: "JSON"
        )
        return PluginQueryResult(
            columns: ["Response"],
            columnTypeNames: ["JSON"],
            rows: [[.text(response.serialized(pretty: true))]],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
            statusMessage: statusMessage,
            columnMeta: [column]
        )
    }
}
