import Foundation

// URLSession carries x-amz-sso_bearer_token, X-Amz-Security-Token and a 307's body across a redirect. AWS and
// Microsoft sign-in endpoints never redirect, so the 3xx comes back as the response whatever session the caller passed.
final class RedirectRefusingTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusingTaskDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
