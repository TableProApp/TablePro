import Foundation
import TableProInfluxDBCore
import TableProPluginKit

internal struct InfluxDBResponse {
    let statusCode: Int
    let headers: [AnyHashable: Any]
    let data: Data

    var isSuccess: Bool { (200 ..< 300).contains(statusCode) }

    func header(_ name: String) -> String? {
        headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
    }

    var error: InfluxError {
        let message = InfluxResponseDecoder.errorMessage(from: data)
        if statusCode == 401 || statusCode == 403 { return .unauthorized(message) }
        return .server(status: statusCode, message: message)
    }
}

internal final class InfluxDBConnection: @unchecked Sendable {
    let baseURL: URL
    let credentials: InfluxCredentials

    private let lock = NSLock()
    private var session: URLSession?
    private var inFlight: [ObjectIdentifier: PluginURLSessionTaskBox] = [:]
    private let queryTimeout: HttpQueryTimeoutBox

    init(
        baseURL: URL,
        credentials: InfluxCredentials,
        skipTLSVerify: Bool,
        connectTimeout: TimeInterval,
        queryTimeout: HttpQueryTimeoutBox
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.queryTimeout = queryTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let delegate = skipTLSVerify ? InfluxDBTrustingDelegate() : PluginRedirectRefusingDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func close() {
        cancelAll()
        lock.withLock {
            session?.invalidateAndCancel()
            session = nil
        }
    }

    func cancelAll() {
        let boxes = lock.withLock {
            defer { inFlight.removeAll() }
            return Array(inFlight.values)
        }
        boxes.forEach { $0.cancel() }
    }

    func send(_ request: InfluxRequest, timeout: TimeInterval? = nil) async throws -> InfluxDBResponse {
        guard let url = request.url(base: baseURL) else {
            throw InfluxError.invalidURL(baseURL.absoluteString + request.path)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = timeout ?? queryTimeout.requestTimeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let taskBox = PluginURLSessionTaskBox()
        let key = ObjectIdentifier(taskBox)
        lock.withLock { inFlight[key] = taskBox }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: key) } }
        return try await withTaskCancellationHandler {
            try await perform(urlRequest, taskBox: taskBox)
        } onCancel: {
            taskBox.cancel()
        }
    }

    private func perform(_ request: URLRequest, taskBox: PluginURLSessionTaskBox) async throws -> InfluxDBResponse {
        try await withCheckedThrowingContinuation { continuation in
            // Made under the lock `close()` invalidates with: a task asked of an invalidated session raises.
            let task: URLSessionDataTask? = lock.withLock {
                session?.dataTask(with: request) { data, response, error in
                    taskBox.finish()
                    if let error {
                        let cancelled = (error as? URLError)?.code == .cancelled
                        continuation.resume(throwing: cancelled ? CancellationError() : error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: InfluxError.malformedResponse("Not an HTTP response"))
                        return
                    }
                    continuation.resume(returning: InfluxDBResponse(
                        statusCode: http.statusCode,
                        headers: http.allHeaderFields,
                        data: data ?? Data()
                    ))
                }
            }
            guard let task else {
                continuation.resume(throwing: InfluxError.notConnected)
                return
            }
            taskBox.set(task)
            task.resume()
        }
    }
}

private final class InfluxDBTrustingDelegate: PluginRedirectRefusingDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
