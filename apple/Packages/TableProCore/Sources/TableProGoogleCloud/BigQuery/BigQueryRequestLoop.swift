//
//  BigQueryRequestLoop.swift
//  TableProGoogleCloud
//

import Foundation

// Set by Stop while a statement's request runs apart from the caller's task.
public final class BigQueryStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public var isStopped: Bool {
        lock.withLock { stopped }
    }

    public func stop() {
        lock.withLock { stopped = true }
    }
}

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

    // Refreshes the token once on 401 and waits out a few 429s. Nil when Stop arrived before a dispatch: a request the
    // server turned away ran nothing, so nothing has to survive Stop and no retry may start a statement after it.
    public static func run(
        isStopped: () -> Bool,
        dispatch: () async throws -> Answer,
        refreshToken: () async -> Void,
        backoff: (Int) async throws -> Void
    ) async throws -> Answer? {
        var rateLimitAttempt = 0
        var refreshedToken = false
        while true {
            guard !isStopped() else { return nil }
            let answer = try await dispatch()
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
