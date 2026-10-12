import Foundation

enum TrinoRedirectPolicy {
    static func refusal(for response: TrinoHTTPResponse, requestURL: URL, useTLS: Bool) -> TrinoError {
        let statusCode = response.statusCode
        guard let target = target(of: response, relativeTo: requestURL), let shown = displayed(target) else {
            return .redirected(statusCode: statusCode, location: nil, advice: .checkAddress)
        }
        guard !useTLS, isUpgradeToTLS(from: requestURL, to: target) else {
            return .redirected(statusCode: statusCode, location: shown, advice: .checkAddress)
        }
        let targetPort = effectivePort(of: target)
        guard targetPort == effectivePort(of: requestURL) else {
            return .redirected(statusCode: statusCode, location: shown, advice: .turnOnTLS(port: targetPort))
        }
        return .tlsHandshakeFailed(kind: .serverRejectedPlaintext, serverMessage: "\(statusCode) redirect to \(shown)")
    }

    private static func target(of response: TrinoHTTPResponse, relativeTo requestURL: URL) -> URL? {
        guard let location = response.headers.first("Location")?.trimmingCharacters(in: .whitespaces),
              !location.isEmpty,
              let url = URL(string: location, relativeTo: requestURL)?.absoluteURL,
              url.scheme != nil,
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func displayed(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private static func isUpgradeToTLS(from requestURL: URL, to target: URL) -> Bool {
        requestURL.scheme?.lowercased() == "http"
            && target.scheme?.lowercased() == "https"
            && requestURL.host?.lowercased() == target.host?.lowercased()
    }

    private static func effectivePort(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
