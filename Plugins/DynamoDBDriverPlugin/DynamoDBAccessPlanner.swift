import Foundation

/// How a Browse request reads DynamoDB.
struct DynamoDBReadPlan: Sendable, Equatable {
    enum Access: Sendable, Equatable {
        case scan
        case query
        case batchGet
        case nothing
    }

    let table: String
    let access: Access
    let indexName: String?
    /// The request bodies, read one after another, each paged to its end.
    let requests: [[String: DynamoDBJSON]]
    let clientPredicates: [DynamoDBClientPredicate]
    let clientMatchAll: Bool
    /// Sort terms DynamoDB could not apply, which the reader applies itself when it holds the
    /// whole result.
    let unsatisfiedOrder: [DynamoDBOrderTerm]

    var hasFilters: Bool {
        !clientPredicates.isEmpty || requests.contains { $0["FilterExpression"] != nil }
    }

    func clientMatches(_ item: DynamoDBItem) -> Bool {
        guard !clientPredicates.isEmpty else { return true }
        if clientMatchAll {
            return clientPredicates.allSatisfy { $0.matches(item) }
        }
        return clientPredicates.contains { $0.matches(item) }
    }

    /// Which request a remembered page position belongs to. A position is the key of an item in
    /// one index, so it cannot start a read of another: a filter that scanned while an index was
    /// still being built queries that index once it is ready.
    var positionKey: String {
        switch access {
        case .scan: return "|scan"
        case .query: return "|query:\(indexName ?? "")"
        case .batchGet: return "|batchGet"
        case .nothing: return "|nothing"
        }
    }

    var summary: String {
        switch access {
        case .query:
            guard let indexName else { return String(localized: "Query on the table") }
            return String(format: String(localized: "Query on index %@"), indexName)
        case .scan:
            return hasFilters ? String(localized: "Scan with filters") : String(localized: "Scan")
        case .batchGet:
            return String(localized: "Get by key")
        case .nothing:
            return String(localized: "No read needed")
        }
    }
}

struct DynamoDBAccessPlanner {
    let schema: DynamoDBTableSchema

    private var translator: DynamoDBFilterTranslator { DynamoDBFilterTranslator(schema: schema) }

    func plan(_ request: DynamoDBBrowseRequest, order: [DynamoDBOrderTerm]) throws -> DynamoDBReadPlan {
        if let reason = request.filters.lazy.compactMap(DynamoDBFilterTranslator.unsupportedReason).first {
            throw DynamoDBError.invalidStatement(reason)
        }
        let known = Set(request.columns).union(schema.allKeyAttributes)
        let paths = request.filters.map { filter -> DynamoDBAttributePath? in
            guard filter.attribute != DynamoDBFilterTranslator.anyAttributeColumn else { return nil }
            return DynamoDBAttributePath.parse(filter.attribute, knownAttributes: known)
        }
        if request.matchAll {
            return planAll(request, paths: paths, order: order)
        }
        return planAny(request, paths: paths, order: order)
    }

    // MARK: - Match All

    private struct Candidate {
        let index: DynamoDBIndex?
        let keys: DynamoDBKeySchema
        let partitionFilters: [Int]
        let sortFilters: [Int]
        let partitionValues: [DynamoDBAttributeValue]?
        let score: Int
    }

    private func planAll(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        order: [DynamoDBOrderTerm]
    ) -> DynamoDBReadPlan {
        guard let candidate = bestCandidate(request, paths: paths, order: order) else {
            return scanPlan(request, paths: paths, order: order)
        }
        let orderOnSortKey = candidate.keys.sort.count == 1
            && order.count == 1
            && order[0].attribute == candidate.keys.sort[0]
            && (candidate.partitionValues?.count ?? 1) == 1

        let partitionValueSets = candidate.partitionValues.map { values in values.map { [$0] } }
            ?? [[]]
        var requests: [[String: DynamoDBJSON]] = []
        var clientPredicates: [DynamoDBClientPredicate] = []
        var isImpossible = false

        for partitionValue in partitionValueSets {
            var context = DynamoDBExpressionContext()
            var keyTerms: [String] = []
            for (position, filterIndex) in candidate.partitionFilters.enumerated() {
                let attribute = candidate.keys.partition[position]
                if let value = partitionValue.first, candidate.partitionValues != nil {
                    let name = context.name(attribute)
                    keyTerms.append("\(name) = \(context.value(value, hint: attribute))")
                } else if let term = translator.keyCondition(request.filters[filterIndex], attribute: attribute, context: &context) {
                    keyTerms.append(term)
                } else {
                    isImpossible = true
                }
            }
            for (position, filterIndex) in candidate.sortFilters.enumerated() {
                let attribute = candidate.keys.sort[position]
                guard let term = translator.keyCondition(request.filters[filterIndex], attribute: attribute, context: &context)
                else {
                    isImpossible = true
                    continue
                }
                keyTerms.append(term)
            }

            let usedFilters = Set(candidate.partitionFilters + candidate.sortFilters)
            let pathKeys = Set(candidate.keys.attributes)
            var filterTerms: [String] = []
            clientPredicates = []
            for (index, filter) in request.filters.enumerated() where !usedFilters.contains(index) {
                let path = paths[index]
                if let path, path.isTopLevel, pathKeys.contains(path.root) {
                    clientPredicates.append(translator.clientPredicate(filter, path: path))
                    continue
                }
                var trial = context
                switch translator.translate(filter, path: path, context: &trial) {
                case .server(let term):
                    context = trial
                    filterTerms.append(term)
                case .client(let predicate): clientPredicates.append(predicate)
                case .never: isImpossible = true
                }
            }

            var body: [String: DynamoDBJSON] = [
                "TableName": .string(schema.name),
                "KeyConditionExpression": .string(keyTerms.joined(separator: " AND "))
            ]
            if let index = candidate.index {
                body["IndexName"] = .string(index.name)
                if index.kind == .local, index.projection != .all {
                    body["Select"] = .string("ALL_ATTRIBUTES")
                }
            }
            if !filterTerms.isEmpty {
                body["FilterExpression"] = .string(filterTerms.joined(separator: " AND "))
            }
            if orderOnSortKey, order[0].descending {
                body["ScanIndexForward"] = .bool(false)
            }
            context.apply(to: &body)
            requests.append(body)
        }

        guard !isImpossible else { return nothingPlan() }
        return DynamoDBReadPlan(
            table: schema.name,
            access: .query,
            indexName: candidate.index?.name,
            requests: requests,
            clientPredicates: clientPredicates,
            clientMatchAll: true,
            unsatisfiedOrder: orderOnSortKey ? [] : order
        )
    }

    private func bestCandidate(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        order: [DynamoDBOrderTerm]
    ) -> Candidate? {
        var candidates: [(DynamoDBIndex?, DynamoDBKeySchema, Int)] = [(nil, schema.keys, 3)]
        for index in schema.indexes where index.isQueryable {
            if index.kind == .global, index.projection != .all { continue }
            candidates.append((index, index.keys, index.kind == .local ? 2 : 1))
        }
        return candidates.compactMap { index, keys, preference in
            candidate(request, paths: paths, index: index, keys: keys, preference: preference, order: order)
        }.max { $0.score < $1.score }
    }

    private func candidate(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        index: DynamoDBIndex?,
        keys: DynamoDBKeySchema,
        preference: Int,
        order: [DynamoDBOrderTerm]
    ) -> Candidate? {
        guard !keys.partition.isEmpty else { return nil }
        var partitionFilters: [Int] = []
        var partitionValues: [DynamoDBAttributeValue]?
        for attribute in keys.partition {
            if let found = filterIndex(request, paths: paths, attribute: attribute, operators: ["="]) {
                partitionFilters.append(found)
                continue
            }
            guard keys.partition.count == 1,
                  let found = filterIndex(request, paths: paths, attribute: attribute, operators: ["IN"]),
                  let type = schema.keyType(of: attribute)
            else { return nil }
            var values: [DynamoDBAttributeValue] = []
            for item in DynamoDBClientPredicate.listItems(request.filters[found].value) {
                guard let typed = translator.typed(item, as: type) else { continue }
                if !values.contains(where: { DynamoDBAccessPlanner.sameKeyValue($0, typed) }) {
                    values.append(typed)
                }
            }
            guard !values.isEmpty, values.count <= 100 else { return nil }
            partitionFilters.append(found)
            partitionValues = values
        }

        var sortFilters: [Int] = []
        for (position, attribute) in keys.sort.enumerated() {
            let isLast = position == keys.sort.count - 1
            let operators = isLast ? DynamoDBFilterTranslator.keyConditionOperators : ["="]
            guard let found = filterIndex(request, paths: paths, attribute: attribute, operators: operators) else { break }
            sortFilters.append(found)
            guard request.filters[found].op == "=" else { break }
        }

        if index != nil, !keys.sort.allSatisfy({ excludesItemsMissing($0, request, paths: paths) }) {
            return nil
        }
        let orderMatches = keys.sort.count == 1 && order.count == 1 && order[0].attribute == keys.sort[0]
        let score = preference + sortFilters.count * 10 + (orderMatches ? 5 : 0)
        return Candidate(
            index: index,
            keys: keys,
            partitionFilters: partitionFilters,
            sortFilters: sortFilters,
            partitionValues: partitionValues,
            score: score
        )
    }

    /// A secondary index holds only the items that carry every one of its key attributes, so it
    /// answers a read only when the filters already reject an item missing `attribute`. Every
    /// operator but `IS NULL` is false on a missing attribute.
    private func excludesItemsMissing(
        _ attribute: String,
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?]
    ) -> Bool {
        request.filters.indices.contains { index in
            guard let path = paths[index], path.isTopLevel, path.root == attribute else { return false }
            return request.filters[index].op != "IS NULL"
        }
    }

    private func filterIndex(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        attribute: String,
        operators: Set<String>
    ) -> Int? {
        request.filters.indices.first { index in
            guard let path = paths[index], path.isTopLevel, path.root == attribute else { return false }
            let filter = request.filters[index]
            guard operators.contains(filter.op), !translator.needsClient(filter) else { return false }
            guard let type = schema.keyType(of: attribute) else { return false }
            if filter.op == "STARTS WITH", type == .number { return false }
            if filter.op == "BETWEEN" {
                guard let bounds = DynamoDBFilterTranslator.bounds(value: filter.value, secondValue: filter.secondValue)
                else { return false }
                return translator.typed(bounds.lower, as: type) != nil && translator.typed(bounds.upper, as: type) != nil
            }
            if filter.op == "IN" { return true }
            return translator.typed(filter.value, as: type) != nil
        }
    }

    // MARK: - Match Any

    private func planAny(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        order: [DynamoDBOrderTerm]
    ) -> DynamoDBReadPlan {
        if let keyed = keyListPlan(request, paths: paths, order: order) {
            return keyed
        }
        if request.filters.contains(where: translator.needsClient) {
            let predicates = request.filters.enumerated().map { index, filter in
                translator.clientPredicate(filter, path: paths[index])
            }
            return DynamoDBReadPlan(
                table: schema.name, access: .scan, indexName: nil,
                requests: [["TableName": .string(schema.name)]],
                clientPredicates: predicates, clientMatchAll: false, unsatisfiedOrder: order
            )
        }
        var context = DynamoDBExpressionContext()
        var terms: [String] = []
        for (index, filter) in request.filters.enumerated() {
            var trial = context
            if case .server(let term) = translator.translate(filter, path: paths[index], context: &trial) {
                context = trial
                terms.append(term)
            }
        }
        guard !terms.isEmpty else { return nothingPlan() }
        var body: [String: DynamoDBJSON] = [
            "TableName": .string(schema.name),
            "FilterExpression": .string(terms.joined(separator: " OR "))
        ]
        context.apply(to: &body)
        return DynamoDBReadPlan(
            table: schema.name, access: .scan, indexName: nil, requests: [body],
            clientPredicates: [], clientMatchAll: true, unsatisfiedOrder: order
        )
    }

    /// `pk = a OR pk = b`, which is how Data Rewind reads rows back: a batch of GetItems when the
    /// table has no sort key, one Query per partition when it has one. A Scan would read the table.
    private func keyListPlan(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        order: [DynamoDBOrderTerm]
    ) -> DynamoDBReadPlan? {
        guard schema.keys.partition.count == 1,
              let partition = schema.keys.partition.first,
              let type = schema.keyType(of: partition),
              !request.filters.isEmpty
        else { return nil }
        var values: [DynamoDBAttributeValue] = []
        for (index, filter) in request.filters.enumerated() {
            guard let path = paths[index], path.isTopLevel, path.root == partition,
                  filter.op == "=", !translator.needsClient(filter),
                  let value = translator.typed(filter.value, as: type)
            else { return nil }
            if !values.contains(where: { Self.sameKeyValue($0, value) }) { values.append(value) }
        }

        if schema.keys.sort.isEmpty {
            let requests = stride(from: 0, to: values.count, by: 100).map { start -> [String: DynamoDBJSON] in
                let keys = values[start..<min(start + 100, values.count)].map { DynamoDBJSON.object([partition: $0.wireJSON]) }
                return ["RequestItems": .object([
                    schema.name: .object(["Keys": .array(Array(keys)), "ConsistentRead": .bool(true)])
                ])]
            }
            return DynamoDBReadPlan(
                table: schema.name, access: .batchGet, indexName: nil, requests: requests,
                clientPredicates: [], clientMatchAll: true, unsatisfiedOrder: order
            )
        }

        let requests = values.map { value -> [String: DynamoDBJSON] in
            var context = DynamoDBExpressionContext()
            let name = context.name(partition)
            var body: [String: DynamoDBJSON] = [
                "TableName": .string(schema.name),
                "KeyConditionExpression": .string("\(name) = \(context.value(value, hint: partition))"),
                "ConsistentRead": .bool(true)
            ]
            context.apply(to: &body)
            return body
        }
        return DynamoDBReadPlan(
            table: schema.name, access: .query, indexName: nil, requests: requests,
            clientPredicates: [], clientMatchAll: true, unsatisfiedOrder: order
        )
    }

    // MARK: - Scan

    private func scanPlan(
        _ request: DynamoDBBrowseRequest,
        paths: [DynamoDBAttributePath?],
        order: [DynamoDBOrderTerm]
    ) -> DynamoDBReadPlan {
        var context = DynamoDBExpressionContext()
        var terms: [String] = []
        var predicates: [DynamoDBClientPredicate] = []
        for (index, filter) in request.filters.enumerated() {
            var trial = context
            switch translator.translate(filter, path: paths[index], context: &trial) {
            case .server(let term):
                context = trial
                terms.append(term)
            case .client(let predicate): predicates.append(predicate)
            case .never: return nothingPlan()
            }
        }
        var body: [String: DynamoDBJSON] = ["TableName": .string(schema.name)]
        if !terms.isEmpty {
            body["FilterExpression"] = .string(terms.joined(separator: " AND "))
        }
        context.apply(to: &body)
        return DynamoDBReadPlan(
            table: schema.name, access: .scan, indexName: nil, requests: [body],
            clientPredicates: predicates, clientMatchAll: true, unsatisfiedOrder: order
        )
    }

    /// Key values DynamoDB treats as one item: `5` and `5.0` are the same Number.
    static func sameKeyValue(_ lhs: DynamoDBAttributeValue, _ rhs: DynamoDBAttributeValue) -> Bool {
        if case .number(let left) = lhs, case .number(let right) = rhs {
            return DynamoDBNumber.areEqual(left, right)
        }
        return lhs == rhs
    }

    private func nothingPlan() -> DynamoDBReadPlan {
        DynamoDBReadPlan(
            table: schema.name, access: .nothing, indexName: nil, requests: [],
            clientPredicates: [], clientMatchAll: true, unsatisfiedOrder: []
        )
    }
}
