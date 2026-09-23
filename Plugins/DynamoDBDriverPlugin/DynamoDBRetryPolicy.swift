import Foundation

/// When a failed request is sent again, and after how long.
///
/// The delays follow the AWS SDKs' standard mode for DynamoDB: full jitter over an exponential
/// base, 25 ms for a transient failure and 1 s for throttling, capped at 20 s, four attempts.
/// Throttling means DynamoDB refused the request, so any request may go again. A 5xx or a dropped
/// connection may have been applied, so only a request that cannot apply twice goes again.
struct DynamoDBRetryPolicy: Sendable {
    static let maximumAttempts = 4
    static let transientBase: TimeInterval = 0.025
    static let throttlingBase: TimeInterval = 1.0
    static let maximumDelay: TimeInterval = 20

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case refreshCredentialsAndRetry
        case correctClockAndRetry
        case fail
    }

    var random: @Sendable () -> Double = { Double.random(in: 0...1) }

    func decision(
        for error: DynamoDBError,
        attempt: Int,
        operation: DynamoDBOperation,
        body: DynamoDBJSON,
        alreadyRefreshedCredentials: Bool,
        alreadyCorrectedClock: Bool
    ) -> Decision {
        guard attempt < Self.maximumAttempts else { return .fail }
        switch error {
        case .service(let service):
            switch service.category {
            case .throttling:
                return .retry(after: delay(base: Self.throttlingBase, attempt: attempt))
            case .transient:
                guard Self.isIdempotent(operation, body: body) else { return .fail }
                return .retry(after: delay(base: Self.transientBase, attempt: attempt))
            case .expiredCredentials:
                return alreadyRefreshedCredentials ? .fail : .refreshCredentialsAndRetry
            case .clockSkew:
                return alreadyCorrectedClock ? .fail : .correctClockAndRetry
            case .authentication, .fatal:
                return .fail
            }
        case .transport:
            guard Self.isIdempotent(operation, body: body) else { return .fail }
            return .retry(after: delay(base: Self.transientBase, attempt: attempt))
        default:
            return .fail
        }
    }

    func delay(base: TimeInterval, attempt: Int) -> TimeInterval {
        let ceiling = min(Self.maximumDelay, base * pow(2, Double(max(attempt - 1, 0))))
        return random() * ceiling
    }

    /// Whether sending the request twice leaves the table as sending it once would.
    static func isIdempotent(_ operation: DynamoDBOperation, body: DynamoDBJSON) -> Bool {
        if operation.isRead { return true }
        switch operation {
        case .putItem, .deleteItem:
            return body["ConditionExpression"] == nil && body["Expected"] == nil
        case .batchWriteItem:
            return true
        case .transactWriteItems, .executeTransaction:
            return body["ClientRequestToken"]?.stringValue?.isEmpty == false
        case .executeStatement:
            return DynamoDBPartiQL.kind(of: body["Statement"]?.stringValue ?? "") == .select
        case .batchExecuteStatement:
            let statements = body["Statements"]?.arrayValue ?? []
            return !statements.isEmpty && statements.allSatisfy {
                DynamoDBPartiQL.kind(of: $0["Statement"]?.stringValue ?? "") == .select
            }
        default:
            return false
        }
    }
}
