//
//  QueryClassifier+DynamoDB.swift
//  TablePro
//

import Foundation

/// Tiering a DynamoDB request by the action it names and what its body asks for.
///
/// A request is one statement of its own, so it is tiered where every split statement is, under each reading. A
/// read is safe. A write is a write, and destructive where the request takes data or a safeguard away: deleting a
/// table, an index or a replica, turning deletion protection or point-in-time recovery off, enabling a TTL that
/// expires items, or deleting items in a batch or a transaction. An action it does not know is destructive, because
/// a plugin from the registry can be newer than the app and run one this list has never heard of. A body it
/// cannot read is the worst its action can do, because the text no longer shows which of those requests will run
/// and the driver may still send it. Text after the body that is not a read window is tiered as statements of its
/// own, which is how a gate reads statements joined without a semicolon. PartiQL keeps the SQL rules, including the
/// PartiQL a request carries in its body.
extension QueryClassifier {
    static func dynamoDBClassification(_ statement: String, databaseType: DatabaseType) -> QueryClassification? {
        guard databaseType == .dynamodb, let request = DynamoDBRequestStatement(statement) else { return nil }
        return QueryClassification(tier: dynamoDBTier(of: request), reachesFilesystemOrExecutesCode: false)
    }

    /// Nil for PartiQL, which the SQL rule answers. A request deletes everything only through the PartiQL it carries
    /// or the statements after it.
    static func dynamoDBDeletesEverything(_ statement: String, databaseType: DatabaseType) -> Bool? {
        guard databaseType == .dynamodb, let request = DynamoDBRequestStatement(statement) else { return nil }
        let carried = request.partiQLStatements ?? []
        let following = request.hasOnlyReadWindowAfterBody ? [] : [request.trailingText]
        return (carried + following).contains { isDangerousQuery($0, databaseType: databaseType) }
    }

    private static func dynamoDBTier(of request: DynamoDBRequestStatement) -> QueryTier {
        guard let action = request.action else { return .destructive }
        guard let body = request.body, body.isObject else { return worstTier(of: action) }
        let floor: QueryTier = action == .deleteTable ? .destructive : .safe
        let requestTier = QueryClassification.worse(floor, dynamoDBBodyTier(action: action, body: body, request: request))
        guard !request.hasOnlyReadWindowAfterBody else { return requestTier }
        return QueryClassification.worse(requestTier, classifyTier(request.trailingText, databaseType: .dynamodb))
    }

    private static func worstTier(of action: DynamoDBRequestAction) -> QueryTier {
        switch action {
        case .deleteTable, .updateTable, .updateTimeToLive, .updateContinuousBackups, .batchWriteItem,
             .transactWriteItems, .executeStatement, .executeTransaction, .batchExecuteStatement:
            return .destructive
        case .browse, .scan, .query, .getItem, .batchGetItem, .transactGetItems, .describeTable, .listTables,
             .describeTimeToLive, .describeContinuousBackups, .listTagsOfResource, .describeLimits, .putItem,
             .updateItem, .deleteItem, .createTable, .tagResource, .untagResource:
            return .write
        }
    }

    private static func dynamoDBBodyTier(
        action: DynamoDBRequestAction,
        body: DynamoDBRequestJSON,
        request: DynamoDBRequestStatement
    ) -> QueryTier {
        switch action {
        case .browse, .scan, .query, .getItem, .batchGetItem, .transactGetItems, .describeTable, .listTables,
             .describeTimeToLive, .describeContinuousBackups, .listTagsOfResource, .describeLimits:
            return .safe
        case .putItem, .updateItem, .deleteItem, .createTable, .tagResource, .untagResource:
            return .write
        case .deleteTable:
            return .destructive
        case .updateTable:
            return updateTableTakesSomethingAway(body) ? .destructive : .write
        case .updateTimeToLive:
            return timeToLiveStaysOff(body) ? .write : .destructive
        case .updateContinuousBackups:
            return pointInTimeRecoveryStaysOn(body) ? .write : .destructive
        case .batchWriteItem:
            return batchDeletesItems(body) ? .destructive : .write
        case .transactWriteItems:
            return transactionDeletesItems(body) ? .destructive : .write
        case .executeStatement, .executeTransaction, .batchExecuteStatement:
            return carriedPartiQLTier(request, floor: action == .executeStatement ? .write : .safe)
        }
    }

    private static func updateTableTakesSomethingAway(_ body: DynamoDBRequestJSON) -> Bool {
        let dropsIndex = body.values(forKey: "GlobalSecondaryIndexUpdates")
            .flatMap(\.elements)
            .contains { $0.hasMember("Delete") }
        let dropsReplica = body.values(forKey: "ReplicaUpdates")
            .flatMap(\.elements)
            .contains { $0.hasMember("Delete") }
        let liftsProtection = body.values(forKey: "DeletionProtectionEnabled").contains { $0.boolValue != true }
        return dropsIndex || dropsReplica || liftsProtection
    }

    /// Enabling a TTL starts DynamoDB deleting every item whose attribute has passed, so only a request that visibly
    /// keeps TTL off is an ordinary write.
    private static func timeToLiveStaysOff(_ body: DynamoDBRequestJSON) -> Bool {
        let settings = body.values(forKey: "TimeToLiveSpecification").flatMap { $0.values(forKey: "Enabled") }
        return !settings.isEmpty && settings.allSatisfy { $0.boolValue == false }
    }

    private static func pointInTimeRecoveryStaysOn(_ body: DynamoDBRequestJSON) -> Bool {
        let settings = body.values(forKey: "PointInTimeRecoverySpecification")
            .flatMap { $0.values(forKey: "PointInTimeRecoveryEnabled") }
        return !settings.isEmpty && settings.allSatisfy { $0.boolValue == true }
    }

    private static func batchDeletesItems(_ body: DynamoDBRequestJSON) -> Bool {
        body.values(forKey: "RequestItems")
            .flatMap(\.memberValues)
            .flatMap(\.elements)
            .contains { $0.hasMember("DeleteRequest") }
    }

    private static func transactionDeletesItems(_ body: DynamoDBRequestJSON) -> Bool {
        body.values(forKey: "TransactItems")
            .flatMap(\.elements)
            .contains { $0.hasMember("Delete") }
    }

    /// The worst tier of the PartiQL a request carries, and a write when any entry hides its statement.
    private static func carriedPartiQLTier(_ request: DynamoDBRequestStatement, floor: QueryTier) -> QueryTier {
        guard let statements = request.partiQLStatements,
              !statements.isEmpty,
              statements.count == request.partiQLEntryCount
        else { return .write }
        return statements.reduce(floor) { worst, statement in
            QueryClassification.worse(worst, classifyTier(statement, databaseType: .dynamodb))
        }
    }
}
