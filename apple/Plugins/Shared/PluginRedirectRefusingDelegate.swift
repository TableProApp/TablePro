import Foundation

// URLSession repeats a driver's credential headers to wherever a redirect points. No engine a driver speaks to
// redirects, so the redirect comes back as the response, as in DynamoDB, BigQuery, Spanner and Trino.
nonisolated class PluginRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
