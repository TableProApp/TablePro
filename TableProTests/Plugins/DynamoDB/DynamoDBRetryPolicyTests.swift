import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB retry policy")
struct DynamoDBRetryPolicyTests {
    struct DelayCase: Sendable, CustomTestStringConvertible {
        let attempt: Int
        let seconds: TimeInterval
        var testDescription: String { "attempt \(attempt)" }
    }

    struct IdempotencyCase: Sendable, CustomTestStringConvertible {
        let label: String
        let operation: DynamoDBOperation
        let body: String
        let isIdempotent: Bool
        var testDescription: String { label }
    }

    private static let fullJitter = DynamoDBRetryPolicy(random: { 1.0 })
    private static let noJitter = DynamoDBRetryPolicy(random: { 0.0 })

    private static func service(_ code: String, status: Int = 400, message: String = "") -> DynamoDBError {
        .service(DynamoDBServiceError(code: code, message: message, httpStatus: status))
    }

    private static func decide(
        _ policy: DynamoDBRetryPolicy,
        _ error: DynamoDBError,
        attempt: Int = 1,
        operation: DynamoDBOperation = .getItem,
        body: DynamoDBJSON = .object([:]),
        refreshed: Bool = false,
        corrected: Bool = false
    ) -> DynamoDBRetryPolicy.Decision {
        policy.decision(
            for: error,
            attempt: attempt,
            operation: operation,
            body: body,
            alreadyRefreshedCredentials: refreshed,
            alreadyCorrectedClock: corrected
        )
    }

    @Test(
        "Throttling waits one second doubled per attempt",
        arguments: [
            DelayCase(attempt: 1, seconds: 1),
            DelayCase(attempt: 2, seconds: 2),
            DelayCase(attempt: 3, seconds: 4)
        ]
    )
    func throttlingDelay(_ testCase: DelayCase) {
        let decision = Self.decide(
            Self.fullJitter, Self.service("ProvisionedThroughputExceededException"),
            attempt: testCase.attempt, operation: .updateItem
        )
        #expect(decision == .retry(after: testCase.seconds))
    }

    @Test("Throttling delays are scaled by the jitter")
    func throttlingDelayJitter() {
        let decision = Self.decide(Self.noJitter, Self.service("ThrottlingException"), attempt: 3, operation: .putItem)
        #expect(decision == .retry(after: 0))
        let half = DynamoDBRetryPolicy(random: { 0.5 })
        #expect(Self.decide(half, Self.service("ThrottlingException"), attempt: 3) == .retry(after: 2))
    }

    @Test("The delay ceiling stops at twenty seconds")
    func delayCeiling() {
        #expect(Self.fullJitter.delay(base: DynamoDBRetryPolicy.throttlingBase, attempt: 5) == 16)
        #expect(Self.fullJitter.delay(base: DynamoDBRetryPolicy.throttlingBase, attempt: 6) == 20)
        #expect(Self.fullJitter.delay(base: DynamoDBRetryPolicy.throttlingBase, attempt: 30) == 20)
        #expect(Self.noJitter.delay(base: DynamoDBRetryPolicy.throttlingBase, attempt: 6) == 0)
    }

    @Test("Throttling retries a request that is not idempotent")
    func throttlingRetriesAnyRequest() {
        let decision = Self.decide(Self.fullJitter, Self.service("RequestLimitExceeded"), operation: .updateItem)
        #expect(decision == .retry(after: 1))
    }

    @Test(
        "A transient failure of an idempotent request waits 25 ms doubled per attempt",
        arguments: [
            DelayCase(attempt: 1, seconds: 0.025),
            DelayCase(attempt: 2, seconds: 0.05),
            DelayCase(attempt: 3, seconds: 0.1)
        ]
    )
    func transientDelay(_ testCase: DelayCase) {
        let decision = Self.decide(
            Self.fullJitter, Self.service("InternalServerError", status: 500), attempt: testCase.attempt
        )
        #expect(decision == .retry(after: testCase.seconds))
    }

    @Test("A transient failure of a request that may have applied is not retried")
    func transientNotIdempotentFails() {
        #expect(Self.decide(Self.fullJitter, Self.service("InternalServerError", status: 500), operation: .updateItem) == .fail)
        #expect(Self.decide(Self.fullJitter, Self.service("SomethingNew", status: 503), operation: .updateItem) == .fail)
    }

    @Test("A transient 5xx of an idempotent request is retried whatever its code")
    func transientAnyCodeRetried() {
        #expect(Self.decide(Self.noJitter, Self.service("SomethingNew", status: 503), operation: .scan) == .retry(after: 0))
    }

    @Test("The fourth attempt is the last", arguments: [4, 5])
    func attemptLimit(_ attempt: Int) {
        #expect(Self.decide(Self.fullJitter, Self.service("ThrottlingException"), attempt: attempt) == .fail)
        #expect(Self.decide(Self.fullJitter, Self.service("InternalServerError", status: 500), attempt: attempt) == .fail)
        #expect(Self.decide(Self.fullJitter, Self.service("ExpiredTokenException"), attempt: attempt) == .fail)
        #expect(Self.decide(Self.fullJitter, .transport("reset"), attempt: attempt) == .fail)
    }

    @Test("An expired token is refreshed once and then fails")
    func expiredTokenRefreshesOnce() {
        let error = Self.service("ExpiredTokenException")
        #expect(Self.decide(Self.fullJitter, error, operation: .updateItem) == .refreshCredentialsAndRetry)
        #expect(Self.decide(Self.fullJitter, error, attempt: 2, operation: .updateItem, refreshed: true) == .fail)
    }

    @Test("A skewed clock is corrected once and then fails")
    func clockSkewCorrectsOnce() {
        let error = Self.service("InvalidSignatureException", message: "Signature expired: 20150830T123600Z is now earlier than 20150830T124100Z")
        #expect(Self.decide(Self.fullJitter, error, operation: .updateItem) == .correctClockAndRetry)
        #expect(Self.decide(Self.fullJitter, error, attempt: 2, operation: .updateItem, corrected: true) == .fail)
        #expect(Self.decide(Self.fullJitter, Self.service("RequestTimeTooSkewed")) == .correctClockAndRetry)
    }

    @Test(
        "Authentication and fatal errors fail at once",
        arguments: [
            "UnrecognizedClientException", "InvalidSignatureException", "AccessDeniedException",
            "ValidationException", "ResourceNotFoundException", "ConditionalCheckFailedException"
        ]
    )
    func authenticationAndFatalFail(_ code: String) {
        #expect(Self.decide(Self.fullJitter, Self.service(code), operation: .scan) == .fail)
    }

    @Test("A transport error is retried only for an idempotent request")
    func transportErrorRetriesIdempotentOnly() {
        #expect(Self.decide(Self.fullJitter, .transport("The network connection was lost."), operation: .query)
            == .retry(after: 0.025))
        #expect(Self.decide(Self.fullJitter, .transport("The network connection was lost."), operation: .updateItem)
            == .fail)
    }

    @Test(
        "Errors the driver raised itself are never retried",
        arguments: [
            DynamoDBError.cancelled, .notConnected, .timedOut(seconds: 30), .invalidResponse("bad"),
            .configuration("bad"), .invalidStatement("bad")
        ]
    )
    func localErrorsFail(_ error: DynamoDBError) {
        #expect(Self.decide(Self.fullJitter, error, operation: .scan) == .fail)
    }

    @Test(
        "Every read is idempotent",
        arguments: DynamoDBOperation.allCases.filter(\.isRead)
    )
    func readsAreIdempotent(_ operation: DynamoDBOperation) {
        #expect(DynamoDBRetryPolicy.isIdempotent(operation, body: .object([:])))
    }

    @Test(
        "Whether a write may be sent twice",
        arguments: [
            IdempotencyCase(label: "PutItem", operation: .putItem, body: #"{"TableName":"t"}"#, isIdempotent: true),
            IdempotencyCase(
                label: "PutItem with a condition", operation: .putItem,
                body: #"{"TableName":"t","ConditionExpression":"attribute_not_exists(pk)"}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "PutItem with legacy Expected", operation: .putItem,
                body: #"{"TableName":"t","Expected":{"pk":{"Exists":false}}}"#, isIdempotent: false
            ),
            IdempotencyCase(label: "DeleteItem", operation: .deleteItem, body: #"{"TableName":"t"}"#, isIdempotent: true),
            IdempotencyCase(
                label: "DeleteItem with a condition", operation: .deleteItem,
                body: #"{"TableName":"t","ConditionExpression":"attribute_exists(pk)"}"#, isIdempotent: false
            ),
            IdempotencyCase(label: "UpdateItem", operation: .updateItem, body: #"{"TableName":"t"}"#, isIdempotent: false),
            IdempotencyCase(
                label: "UpdateItem with a condition", operation: .updateItem,
                body: #"{"TableName":"t","ConditionExpression":"attribute_exists(pk)"}"#, isIdempotent: false
            ),
            IdempotencyCase(label: "BatchWriteItem", operation: .batchWriteItem, body: #"{"RequestItems":{}}"#, isIdempotent: true),
            IdempotencyCase(
                label: "TransactWriteItems with a token", operation: .transactWriteItems,
                body: #"{"TransactItems":[],"ClientRequestToken":"f3c1"}"#, isIdempotent: true
            ),
            IdempotencyCase(
                label: "TransactWriteItems without a token", operation: .transactWriteItems,
                body: #"{"TransactItems":[]}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "TransactWriteItems with an empty token", operation: .transactWriteItems,
                body: #"{"TransactItems":[],"ClientRequestToken":""}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "ExecuteTransaction with a token", operation: .executeTransaction,
                body: #"{"TransactStatements":[],"ClientRequestToken":"f3c1"}"#, isIdempotent: true
            ),
            IdempotencyCase(
                label: "ExecuteTransaction without a token", operation: .executeTransaction,
                body: #"{"TransactStatements":[]}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "ExecuteStatement SELECT", operation: .executeStatement,
                body: #"{"Statement":"SELECT * FROM \"t\" WHERE pk = 'a'"}"#, isIdempotent: true
            ),
            IdempotencyCase(
                label: "ExecuteStatement lowercase select", operation: .executeStatement,
                body: #"{"Statement":"  select * from t"}"#, isIdempotent: true
            ),
            IdempotencyCase(
                label: "ExecuteStatement UPDATE", operation: .executeStatement,
                body: #"{"Statement":"UPDATE \"t\" SET n = n + 1 WHERE pk = 'a'"}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "ExecuteStatement INSERT", operation: .executeStatement,
                body: #"{"Statement":"INSERT INTO \"t\" VALUE {'pk': 'a'}"}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "ExecuteStatement with no statement", operation: .executeStatement,
                body: #"{}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "BatchExecuteStatement all SELECT", operation: .batchExecuteStatement,
                body: #"{"Statements":[{"Statement":"SELECT * FROM t WHERE pk = 'a'"},{"Statement":"SELECT * FROM t WHERE pk = 'b'"}]}"#,
                isIdempotent: true
            ),
            IdempotencyCase(
                label: "BatchExecuteStatement mixed", operation: .batchExecuteStatement,
                body: #"{"Statements":[{"Statement":"SELECT * FROM t WHERE pk = 'a'"},{"Statement":"DELETE FROM t WHERE pk = 'b'"}]}"#,
                isIdempotent: false
            ),
            IdempotencyCase(
                label: "BatchExecuteStatement empty", operation: .batchExecuteStatement,
                body: #"{"Statements":[]}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "CreateTable", operation: .createTable, body: #"{"TableName":"t"}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "DeleteTable", operation: .deleteTable, body: #"{"TableName":"t"}"#, isIdempotent: false
            ),
            IdempotencyCase(
                label: "UpdateTimeToLive", operation: .updateTimeToLive, body: #"{"TableName":"t"}"#, isIdempotent: false
            )
        ]
    )
    func writeIdempotency(_ testCase: IdempotencyCase) throws {
        let body = try DynamoDBJSON.parse(testCase.body)
        #expect(DynamoDBRetryPolicy.isIdempotent(testCase.operation, body: body) == testCase.isIdempotent)
    }
}
