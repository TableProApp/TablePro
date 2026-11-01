//
//  SameOriginRedirectGuard.swift
//  TablePro
//

import Foundation

// URLSession carries a request's Authorization header to wherever a redirect points, so only same-origin redirects are followed.
internal final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: Origin?

    init(origin: URL) {
        self.origin = Origin(origin)
    }

    func allows(_ target: URL) -> Bool {
        guard let origin, let destination = Origin(target) else { return false }
        return origin == destination
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let target = request.url, allows(target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            guard let port = url.port ?? Self.defaultPort(scheme) else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }

        private static func defaultPort(_ scheme: String) -> Int? {
            switch scheme {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }
    }
}
