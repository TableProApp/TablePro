import Foundation

/// Caps each request at what is left of a connect's time budget, read as the request goes out, so
/// the second request of an impersonation exchange gets only what the first left.
public struct GoogleDeadlineHTTPClient: GoogleHTTPClient {
    private let base: any GoogleHTTPClient
    private let remainingSeconds: @Sendable (TimeInterval) -> TimeInterval

    /// `remainingSeconds` receives the request's own timeout and returns the one to use.
    public init(base: any GoogleHTTPClient, remainingSeconds: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.base = base
        self.remainingSeconds = remainingSeconds
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = remainingSeconds(request.timeoutInterval)
        return try await base.send(request)
    }
}
