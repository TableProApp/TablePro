import Foundation

internal struct GoogleAccessToken: Sendable, Equatable {
    let value: String
    let expiresAt: Date
}

internal protocol GoogleAccessTokenSource: Sendable {
    func fetchAccessToken() async throws -> GoogleAccessToken
}

internal typealias GoogleClock = @Sendable () -> Date

internal actor GoogleCachedAccessTokenProvider: GoogleAccessTokenProviding {
    static let refreshMargin: TimeInterval = 300

    private let source: any GoogleAccessTokenSource
    private let now: GoogleClock
    private var cached: GoogleAccessToken?
    private var inFlight: Task<GoogleAccessToken, Error>?

    init(source: any GoogleAccessTokenSource, now: @escaping GoogleClock = { Date() }) {
        self.source = source
        self.now = now
    }

    func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return cached.value
        }
        if let inFlight {
            return try await inFlight.value.value
        }
        let source = source
        let task = Task { try await source.fetchAccessToken() }
        inFlight = task
        do {
            let token = try await task.value
            finish(task, with: token)
            return token.value
        } catch {
            finish(task, with: nil)
            throw error
        }
    }

    func invalidateCachedToken() async {
        cached = nil
    }

    private func finish(_ task: Task<GoogleAccessToken, Error>, with token: GoogleAccessToken?) {
        guard inFlight == task else { return }
        inFlight = nil
        if let token {
            cached = token
        }
    }
}
