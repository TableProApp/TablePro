import Foundation

// URLSession carries every header but Authorization across a redirect and resends a 307's body, so a redirect
// off the request's origin comes back as the response.
public final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = SameOriginRedirects()

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.follows(request.url, from: task.originalRequest?.url) ? request : nil)
    }

    public static func follows(_ target: URL?, from origin: URL?) -> Bool {
        origin.flatMap(HTTPOrigin.init)?.contains(target) == true
    }
}
