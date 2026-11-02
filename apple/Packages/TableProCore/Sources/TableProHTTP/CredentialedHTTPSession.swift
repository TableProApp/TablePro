import Foundation

public enum CredentialedHTTPError: LocalizedError, Equatable, Sendable {
    case crossOrigin(String)
    case redirected(status: Int, location: String)

    public var errorDescription: String? {
        switch self {
        case .crossOrigin(let address):
            return String(
                format: String(localized: "%@ is not on the server this connection uses, so TablePro did not send the credentials there."),
                address
            )
        case let .redirected(status, location):
            return String(
                format: String(localized: "The server answered HTTP %lld with a redirect to %@, which is not the server this connection uses. TablePro did not follow it."),
                Int64(status),
                location
            )
        }
    }
}

public final class CredentialedHTTPSession: Sendable {
    public let origin: HTTPOrigin
    private let session: URLSession
    private let authorize: @Sendable (inout URLRequest) -> Void

    // The credential goes on each request here, never in httpAdditionalHeaders: URLSession sends those to any host.
    public init(origin: HTTPOrigin, session: URLSession, authorize: @escaping @Sendable (inout URLRequest) -> Void) {
        self.origin = origin
        self.session = session
        self.authorize = authorize
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard origin.contains(request.url) else {
            throw CredentialedHTTPError.crossOrigin(request.url?.absoluteString ?? "")
        }
        var authorized = request
        authorize(&authorized)
        let redirects = CredentialedRedirectGuard(origin: origin, authorize: authorize)
        let (data, response) = try await session.data(for: authorized, delegate: redirects)
        if let refused = redirects.refused {
            throw refused
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func followServerURL(_ value: String) throws -> URL {
        try origin.followServerURL(value)
    }
}

// A task delegate answers before the session's own, so the caller's session keeps its TLS delegate.
// URLSession drops Authorization on every redirect and keeps every other header, so a same-origin
// follow gets the credential again and any other redirect is not followed at all.
final class CredentialedRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: HTTPOrigin
    private let authorize: @Sendable (inout URLRequest) -> Void
    private let lock = NSLock()
    private var refusal: CredentialedHTTPError?

    init(origin: HTTPOrigin, authorize: @escaping @Sendable (inout URLRequest) -> Void) {
        self.origin = origin
        self.authorize = authorize
    }

    var refused: CredentialedHTTPError? {
        lock.withLock { refusal }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard origin.contains(request.url) else {
            let location = request.url?.absoluteString ?? ""
            lock.withLock { refusal = .redirected(status: response.statusCode, location: location) }
            completionHandler(nil)
            return
        }
        var next = request
        authorize(&next)
        completionHandler(next)
    }
}
