import Foundation

public enum BigQueryRequestLoop {
    public struct Answer: Sendable {
        public let status: Int
        public let data: Data

        public init(status: Int, data: Data) {
            self.status = status
            self.data = data
        }
    }

    public static let rateLimitRetries = 3
    private static let unauthorizedStatus = 401
    private static let rateLimitedStatus = 429

    // Nil when Stop came before a send. Stop is read again after the token fetch, which can take a round trip.
    public static func run<Token>(
        signals: BigQueryRequestSignals,
        authorize: () async throws -> Token,
        send: (Token) async throws -> Answer,
        refreshToken: () async -> Void,
        backoff: (Int) async throws -> Void
    ) async throws -> Answer? {
        var rateLimitAttempt = 0
        var refreshedToken = false
        while true {
            guard !signals.isStopped() else { return nil }
            let token = try await authorize()
            guard signals.beginAttempt() else { return nil }
            let answer = try await send(token)
            if answer.status == unauthorizedStatus, !refreshedToken {
                refreshedToken = true
                await refreshToken()
            } else if answer.status == rateLimitedStatus, rateLimitAttempt < rateLimitRetries {
                rateLimitAttempt += 1
                try await backoff(rateLimitAttempt)
            } else {
                return answer
            }
        }
    }
}
