import Foundation

public protocol GoogleHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGoogleHTTPClient: GoogleHTTPClient {
    private static let session = URLSession(
        configuration: .ephemeral,
        delegate: GoogleRedirectRefusingDelegate(),
        delegateQueue: nil
    )

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw GoogleAuthError.transport(GoogleURLErrorName.name(for: error.code))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAuthError.transport(GoogleURLErrorName.invalidResponse)
        }
        return (data, httpResponse)
    }
}

internal final class GoogleRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

internal enum GoogleURLErrorName {
    static let invalidResponse = "invalidResponse"

    private static let names: [URLError.Code: String] = [
        .cancelled: "cancelled",
        .timedOut: "timedOut",
        .notConnectedToInternet: "notConnectedToInternet",
        .networkConnectionLost: "networkConnectionLost",
        .cannotFindHost: "cannotFindHost",
        .cannotConnectToHost: "cannotConnectToHost",
        .dnsLookupFailed: "dnsLookupFailed",
        .secureConnectionFailed: "secureConnectionFailed",
        .serverCertificateUntrusted: "serverCertificateUntrusted",
        .serverCertificateHasBadDate: "serverCertificateHasBadDate",
        .serverCertificateNotYetValid: "serverCertificateNotYetValid",
        .serverCertificateHasUnknownRoot: "serverCertificateHasUnknownRoot",
        .clientCertificateRejected: "clientCertificateRejected",
        .badServerResponse: "badServerResponse",
        .badURL: "badURL",
        .unsupportedURL: "unsupportedURL",
        .dataNotAllowed: "dataNotAllowed",
        .internationalRoamingOff: "internationalRoamingOff",
        .callIsActive: "callIsActive",
        .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection"
    ]

    static func name(for code: URLError.Code) -> String {
        names[code] ?? "URLError \(code.rawValue)"
    }
}
