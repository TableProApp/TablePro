import Foundation

public struct GoogleRESTCredential: Sendable {
    public let token: @Sendable () async throws -> String?
    public let invalidate: @Sendable () async -> Void
    public let quotaProject: String?

    public init(
        token: @escaping @Sendable () async throws -> String?,
        invalidate: @escaping @Sendable () async -> Void = {},
        quotaProject: String? = nil
    ) {
        self.token = token
        self.invalidate = invalidate
        self.quotaProject = quotaProject
    }

    public init(provider: any GoogleAccessTokenProviding, quotaProject: String?) {
        self.init(
            token: { try await provider.accessToken() },
            invalidate: { await provider.invalidateCachedToken() },
            quotaProject: quotaProject
        )
    }

    /// `projectHint` is the project the key or the login names. Application Default Credentials
    /// that name none fall back to `GOOGLE_CLOUD_PROJECT`, as the gcloud tools do.
    public static func resolving(
        _ source: GoogleCredentialSource,
        scopes: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        http: any GoogleHTTPClient = URLSessionGoogleHTTPClient()
    ) throws -> (credential: GoogleRESTCredential, projectHint: String?) {
        let credentials = try GoogleTokenProviders.credentials(
            from: source,
            scopes: scopes,
            readFile: readFile,
            environment: environment,
            http: http
        )
        let environmentProject = source == .applicationDefault
            ? GoogleCredentialDocument.trimmed(environment["GOOGLE_CLOUD_PROJECT"] ?? "")
            : ""
        return (
            GoogleRESTCredential(provider: credentials.tokenProvider, quotaProject: credentials.quotaProject),
            credentials.projectHint ?? (environmentProject.isEmpty ? nil : environmentProject)
        )
    }
}

/// A 401 drops the cached token and retries once, since a token can expire between being cached
/// and being used.
public struct GoogleRESTRequester: Sendable {
    public let transport: any GoogleRESTTransport
    public let credential: GoogleRESTCredential
    public let timeout: @Sendable () -> TimeInterval

    public init(transport: any GoogleRESTTransport, credential: GoogleRESTCredential, timeout: @escaping @Sendable () -> TimeInterval) {
        self.transport = transport
        self.credential = credential
        self.timeout = timeout
    }

    public func send(
        method: String,
        url: URL,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeoutOverride: TimeInterval? = nil
    ) async throws -> GoogleRESTResponse {
        var response = try await attempt(method, url, body, headers, timeoutOverride)
        if response.statusCode == 401 {
            await credential.invalidate()
            response = try await attempt(method, url, body, headers, timeoutOverride)
        }
        return response
    }

    private func attempt(
        _ method: String,
        _ url: URL,
        _ body: Data?,
        _ extraHeaders: [String: String],
        _ timeoutOverride: TimeInterval?
    ) async throws -> GoogleRESTResponse {
        var headers = extraHeaders
        if let token = try await credential.token() {
            headers["Authorization"] = "Bearer " + token
        }
        if let project = credential.quotaProject, headers["x-goog-user-project"] == nil {
            headers["x-goog-user-project"] = project
        }
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        try Task.checkCancellation()
        return try await transport.send(GoogleRESTRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeoutInterval: timeoutOverride ?? timeout()
        ))
    }
}
