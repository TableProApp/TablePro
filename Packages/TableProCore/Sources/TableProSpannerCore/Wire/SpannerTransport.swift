import Foundation

public enum SpannerTransportError: Error, Sendable, Equatable {
    case closed
    case cancelled
    case timedOut
    case network(String)
    case invalidResponse
}

public protocol SpannerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
    func close() async
}

internal enum SpannerURLErrorMapping {
    private static let names: [URLError.Code: String] = [
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
        .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection"
    ]

    static func transportError(for error: Error) -> Error {
        if error is CancellationError || error is SpannerTransportError {
            return error
        }
        guard let urlError = error as? URLError else {
            return SpannerTransportError.network(String(describing: type(of: error)))
        }
        switch urlError.code {
        case .cancelled:
            return SpannerTransportError.cancelled
        case .timedOut:
            return SpannerTransportError.timedOut
        default:
            return SpannerTransportError.network(names[urlError.code] ?? "URLError \(urlError.code.rawValue)")
        }
    }
}
