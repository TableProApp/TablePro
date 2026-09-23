//
//  QueryClassifierDynamoDBTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryClassifier DynamoDB requests")
struct QueryClassifierDynamoDBTests {
    private func tier(_ sql: String) -> QueryTier {
        QueryClassifier.classifyTier(sql, databaseType: .dynamodb)
    }

    @Test("Browse and every read action are safe", arguments: [
        #"Browse {"TableName": "orders", "Filters": [], "Match": "All", "Columns": ["pk"]}"#,
        #"Browse {"TableName": "orders"} ORDER BY "createdAt" DESC LIMIT 100 OFFSET 200"#,
        #"Scan {"TableName": "orders"}"#,
        #"scan {"TableName": "orders"}"#,
        #"Scan {"TableName": "orders"} ORDER BY "a" ASC, total DESC LIMIT 5 OFFSET 10;"#,
        ##"Query {"TableName": "orders", "KeyConditionExpression": "#pk = :pk"} LIMIT 20"##,
        #"GetItem {"TableName": "orders", "Key": {"pk": {"S": "a"}}}"#,
        #"BatchGetItem {"RequestItems": {"orders": {"Keys": [{"pk": {"S": "a"}}]}}}"#,
        #"TransactGetItems {"TransactItems": [{"Get": {"TableName": "orders", "Key": {"pk": {"S": "a"}}}}]}"#,
        #"DescribeTable {"TableName": "orders"}"#,
        #"ListTables {}"#,
        #"DescribeTimeToLive {"TableName": "orders"}"#,
        #"DescribeContinuousBackups {"TableName": "orders"}"#,
        #"ListTagsOfResource {"ResourceArn": "arn:aws:dynamodb:us-east-1:1:table/orders"}"#,
        #"DescribeLimits {}"#
    ])
    func readsAreSafe(_ sql: String) {
        #expect(tier(sql) == .safe)
    }

    @Test("Item and table writes that take nothing away are writes", arguments: [
        #"PutItem {"TableName": "orders", "Item": {"pk": {"S": "a"}}}"#,
        #"UpdateItem {"TableName": "orders", "Key": {"pk": {"S": "a"}}, "UpdateExpression": "SET n = :n"}"#,
        #"DeleteItem {"TableName": "orders", "Key": {"pk": {"S": "a"}}}"#,
        #"CreateTable {"TableName": "orders", "BillingMode": "PAY_PER_REQUEST"}"#,
        #"UpdateTable {"TableName": "orders", "BillingMode": "PROVISIONED"}"#,
        #"UpdateTable {"TableName": "orders", "DeletionProtectionEnabled": true}"#,
        #"UpdateTable {"TableName": "orders", "GlobalSecondaryIndexUpdates": [{"Create": {"IndexName": "byDate"}}]}"#,
        #"UpdateTimeToLive {"TableName": "orders", "TimeToLiveSpecification": {"Enabled": false, "AttributeName": "ttl"}}"#,
        #"UpdateContinuousBackups {"TableName": "orders", "PointInTimeRecoverySpecification": {"PointInTimeRecoveryEnabled": true}}"#,
        #"BatchWriteItem {"RequestItems": {"orders": [{"PutRequest": {"Item": {"DeleteRequest": {"S": "a"}}}}]}}"#,
        #"TransactWriteItems {"TransactItems": [{"Put": {"TableName": "orders", "Item": {"Delete": {"S": "a"}}}}]}"#,
        #"TagResource {"ResourceArn": "arn", "Tags": [{"Key": "team", "Value": "data"}]}"#,
        #"UntagResource {"ResourceArn": "arn", "TagKeys": ["team"]}"#
    ])
    func writesAreWrites(_ sql: String) {
        #expect(tier(sql) == .write)
    }

    @Test("A request that drops data or a safeguard is destructive", arguments: [
        #"DeleteTable {"TableName": "orders"}"#,
        #"deletetable {"TableName": "orders"}"#,
        #"DeleteTable {"TableName": "orders""#,
        #"UpdateTable {"TableName": "orders", "GlobalSecondaryIndexUpdates": [{"Delete": {"IndexName": "byDate"}}]}"#,
        #"UpdateTable {"TableName": "orders", "ReplicaUpdates": [{"Delete": {"RegionName": "eu-west-1"}}]}"#,
        #"UpdateTable {"TableName": "orders", "DeletionProtectionEnabled": false}"#,
        #"UpdateTimeToLive {"TableName": "orders", "TimeToLiveSpecification": {"Enabled": true, "AttributeName": "ttl"}}"#,
        #"UpdateContinuousBackups {"TableName": "orders", "PointInTimeRecoverySpecification": {"PointInTimeRecoveryEnabled": false}}"#,
        #"BatchWriteItem {"RequestItems": {"orders": [{"PutRequest": {"Item": {}}}, {"DeleteRequest": {"Key": {}}}]}}"#,
        #"TransactWriteItems {"TransactItems": [{"Put": {"TableName": "a"}}, {"Delete": {"TableName": "b"}}]}"#,
        "-- tidy up\nDeleteTable {\"TableName\": \"orders\"}"
    ])
    func removalsAreDestructive(_ sql: String) {
        #expect(tier(sql) == .destructive)
    }

    @Test("A key spelled with a Unicode escape is still read")
    func unicodeEscapedKeyIsRead() {
        let sql = #"UpdateTable {"TableName": "t", "GlobalSecondaryIndexUpdates": [{"\u0044elete": {"IndexName": "i"}}]}"#
        #expect(tier(sql) == .destructive)
    }

    @Test("PartiQL a request carries is tiered by the SQL rules")
    func carriedPartiQLIsTiered() {
        #expect(tier(#"ExecuteTransaction {"TransactStatements": [{"Statement": "SELECT * FROM t WHERE pk = ?"}]}"#) == .safe)
        #expect(tier(#"BatchExecuteStatement {"Statements": [{"Statement": "SELECT * FROM t"}, {"Statement": "SELECT * FROM u"}]}"#) == .safe)
        #expect(tier(#"BatchExecuteStatement {"Statements": [{"Statement": "SELECT * FROM t"}, {"Statement": "UPDATE t SET a = 1 WHERE pk = 'x'"}]}"#) == .write)
        #expect(tier(#"ExecuteTransaction {"TransactStatements": [{"Statement": "INSERT INTO t VALUE {'pk': 'a'}"}]}"#) == .write)
        #expect(tier(#"ExecuteStatement {"Statement": "SELECT * FROM t"}"#) == .write)
    }

    @Test("A carried entry whose statement the classifier cannot read is a write", arguments: [
        #"BatchExecuteStatement {"Statements": [{"Statement": "SELECT * FROM t"}, {"Parameters": []}]}"#,
        #"ExecuteTransaction {"TransactStatements": []}"#,
        #"ExecuteTransaction {"TransactStatements": "SELECT * FROM t"}"#,
        #"ExecuteStatement {"Statement": 42}"#
    ])
    func unreadableCarriedPartiQLIsAWrite(_ sql: String) {
        #expect(tier(sql) == .write)
    }

    @Test("An unreadable item write or a write after the body is a write", arguments: [
        #"PutItem {"TableName": }"#,
        #"Scan {"TableName": "orders""#,
        #"Scan {"TableName": "orders"} DELETE FROM orders"#,
        "Scan {\"TableName\": \"orders\"}\nDeleteItem {\"TableName\": \"orders\"}",
        #"Scan {"TableName": "orders"} LIMIT ten"#,
        #"Scan {"TableName": "orders"} ORDER BY"#
    ])
    func unreadableRequestsAreWrites(_ sql: String) {
        #expect(tier(sql) == .write)
    }

    @Test("An action the app does not know is destructive, whatever its body says", arguments: [
        #"Frobnicate {"TableName": "orders"}"#,
        #"DeleteBackup {"BackupArn": "arn:aws:dynamodb:us-east-1:1:table/orders/backup/1"}"#
    ])
    func unknownActionsAreDestructive(_ sql: String) {
        #expect(tier(sql) == .destructive)
    }

    @Test("The app knows every action the driver runs, and no other")
    func actionListsMatchTheDriver() {
        let classified = Set(DynamoDBRequestAction.allCases.map(\.rawValue)).subtracting(["Browse"])
        let executed = Set(DynamoDBOperation.allCases.map(\.rawValue))

        #expect(classified == executed)
    }

    @Test("A body the classifier cannot read is the worst its action can do", arguments: [
        "UpdateTable", "UpdateTimeToLive", "UpdateContinuousBackups", "BatchWriteItem", "TransactWriteItems",
        "ExecuteStatement", "ExecuteTransaction", "BatchExecuteStatement", "DeleteTable"
    ])
    func unreadableBodyTakesTheWorstTier(_ action: String) {
        let tooDeep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let padded = #"\#(action) {"TableName": "orders", "Pad": \#(tooDeep)}"#
        let broken = #"\#(action) {"TableName": }"#

        #expect(tier(padded) == .destructive)
        #expect(tier(broken) == .destructive)
    }

    @Test("The classifier reads every body as deep as the driver sends", arguments: [1, 63, 64, 65, 127, 128, 129, 200])
    func classifierReadsWhatTheDriverReads(_ depth: Int) {
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let body = #"{"TableName": "orders", "Pad": \#(nested)}"#

        let driverReads = (try? DynamoDBJSON.parse(body)) != nil
        let classifierReads = DynamoDBRequestJSON.parsePrefix(body[...]).map { $0.remainder.isEmpty } ?? false

        #expect(classifierReads == driverReads)
    }

    @Test("Requests joined without a semicolon are each tiered")
    func joinedRequestsAreEachTiered() {
        #expect(tier("Scan {\"TableName\": \"a\"}\nQuery {\"TableName\": \"b\"} LIMIT 5") == .safe)
        #expect(tier("Scan {\"TableName\": \"a\"}\nDeleteTable {\"TableName\": \"a\"}") == .destructive)
        #expect(QueryClassifier.isDangerousQuery(
            "Scan {\"TableName\": \"a\"}\nDELETE FROM a", databaseType: .dynamodb
        ))
    }

    @Test("A script is tiered by its worst statement")
    func multiStatementTakesTheWorstTier() {
        #expect(tier(#"Scan {"TableName": "a"}; Query {"TableName": "b"}; SELECT * FROM "c""#) == .safe)
        #expect(tier(#"Scan {"TableName": "a"}; PutItem {"TableName": "a", "Item": {}}"#) == .write)
        #expect(tier(#"Scan {"TableName": "a"}; DeleteTable {"TableName": "a"}"#) == .destructive)
        #expect(tier(#"SELECT * FROM "a"; UpdateTimeToLive {"TableName": "a", "TimeToLiveSpecification": {"Enabled": true}}"#)
            == .destructive)
    }

    @Test("An escaped quote inside a request string does not end the request")
    func escapedQuoteStaysInsideTheRequest() {
        #expect(tier(#"PutItem {"TableName": "t", "Item": {"a": {"S": "x\";y"}}}"#) == .write)
    }

    @Test("The plain reading of an escaped quote still reaches the gate")
    func plainReadingOfAnEscapedQuoteIsCounted() {
        #expect(tier(#"PutItem {"TableName": "t", "Item": {"a": {"S": "x\";DROP"}}}"#) == .destructive)
    }

    @Test("PartiQL keeps the SQL rules")
    func partiQLKeepsSQLRules() {
        #expect(tier(#"SELECT * FROM "orders" WHERE pk = 'a'"#) == .safe)
        #expect(tier(#"INSERT INTO "orders" VALUE {'pk': 'a'}"#) == .write)
        #expect(tier(#"DELETE FROM "orders" WHERE pk = 'a'"#) == .write)
        #expect(QueryClassifier.isDangerousQuery(#"DELETE FROM "orders""#, databaseType: .dynamodb))
        #expect(!QueryClassifier.isDangerousQuery(#"DELETE FROM "orders" WHERE pk = 'a'"#, databaseType: .dynamodb))
    }

    @Test("A request is dangerous when it is destructive or carries a DELETE with no WHERE")
    func dangerousRequests() {
        #expect(QueryClassifier.isDangerousQuery(#"DeleteTable {"TableName": "orders"}"#, databaseType: .dynamodb))
        #expect(QueryClassifier.isDangerousQuery(
            #"ExecuteStatement {"Statement": "DELETE FROM orders"}"#, databaseType: .dynamodb
        ))
        #expect(QueryClassifier.isDangerousQuery(
            #"BatchExecuteStatement {"Statements": [{"Statement": "SELECT * FROM a"}, {"Statement": "DELETE FROM b"}]}"#,
            databaseType: .dynamodb
        ))
        #expect(!QueryClassifier.isDangerousQuery(
            #"ExecuteTransaction {"TransactStatements": [{"Statement": "DELETE FROM b WHERE pk = 'a'"}]}"#,
            databaseType: .dynamodb
        ))
        #expect(!QueryClassifier.isDangerousQuery(
            #"DeleteItem {"TableName": "orders", "Key": {"pk": {"S": "a"}}}"#, databaseType: .dynamodb
        ))
        #expect(!QueryClassifier.isDangerousQuery(#"Scan {"TableName": "orders"}"#, databaseType: .dynamodb))
    }

    @Test("No DynamoDB request reaches the filesystem or runs code")
    func requestsNeverReachTheFilesystem() {
        let sql = #"ExecuteStatement {"Statement": "SELECT LOAD_FILE('/etc/passwd') FROM t"}"#
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .dynamodb))
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(#"DeleteTable {"TableName": "t"}"#, databaseType: .dynamodb))
    }

    @Test("Another engine's text is never read as a DynamoDB request")
    func otherEnginesIgnoreTheRequestForm() {
        #expect(QueryClassifier.classifyTier(#"Scan {"TableName": "orders"}"#, databaseType: .postgresql) == .write)
    }
}

@Suite("CatalogChangeClassifier DynamoDB requests")
struct CatalogChangeClassifierDynamoDBTests {
    private func kinds(_ sql: String) -> CatalogObjectKinds {
        CatalogChangeClassifier.effect(of: sql, databaseType: .dynamodb).kinds
    }

    @Test("Creating, changing and dropping a table refresh the tables", arguments: [
        #"CreateTable {"TableName": "orders"}"#,
        #"UpdateTable {"TableName": "orders", "BillingMode": "PAY_PER_REQUEST"}"#,
        #"DeleteTable {"TableName": "orders"}"#,
        #"deleteTable {"TableName": "orders"}"#
    ])
    func tableActionsChangeTheCatalog(_ sql: String) {
        #expect(kinds(sql) == .tables)
    }

    @Test("Reads, item writes and PartiQL leave the catalog alone", arguments: [
        #"Browse {"TableName": "orders"} LIMIT 100"#,
        #"Scan {"TableName": "orders"}"#,
        #"PutItem {"TableName": "orders", "Item": {}}"#,
        #"UpdateTimeToLive {"TableName": "orders", "TimeToLiveSpecification": {"Enabled": true}}"#,
        #"SELECT * FROM "orders""#,
        #"DELETE FROM "orders" WHERE pk = 'a'"#
    ])
    func otherStatementsLeaveTheCatalogAlone(_ sql: String) {
        #expect(kinds(sql).isEmpty)
    }
}
