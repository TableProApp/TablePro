import Foundation
import os
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
}

internal final class InfluxDBConnection: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "InfluxDBConnection")

    private let lock = NSLock()
    private var session: URLSession?
    private var inFlight: [ObjectIdentifier: PluginURLSessionTaskBox] = [:]

    let baseURL: URL
    let credentials: InfluxCredentials
    private let skipTLSVerify: Bool
    private let queryTimeout: HttpQueryTimeoutBox

    init(baseURL: URL, credentials: InfluxCredentials, skipTLSVerify: Bool, queryTimeout: HttpQueryTimeoutBox) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.skipTLSVerify = skipTLSVerify
        self.queryTimeout = queryTimeout
    }

    func open(connectTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }
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
            let boxes = Array(inFlight.values)
            inFlight.removeAll()
            return boxes
        }
        boxes.forEach { $0.cancel() }
    }

    func send(_ request: InfluxRequest, timeout: TimeInterval? = nil) async throws -> InfluxDBResponse {
        guard let session = lock.withLock({ session }) else { throw InfluxError.notConnected }
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
            try await perform(urlRequest, session: session, taskBox: taskBox)
        } onCancel: {
            taskBox.cancel()
        }
    }

    private func perform(
        _ request: URLRequest,
        session: URLSession,
        taskBox: PluginURLSessionTaskBox
    ) async throws -> InfluxDBResponse {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                taskBox.finish()
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
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
            taskBox.set(task)
            task.resume()
        }
    }

    static func error(for response: InfluxDBResponse) -> InfluxError {
        let message = InfluxResponseDecoder.errorMessage(from: response.data)
        if response.statusCode == 401 || response.statusCode == 403 {
            return .unauthorized(message)
        }
        return .server(status: response.statusCode, message: message)
    }
}

extension InfluxDBConnection: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard skipTLSVerify,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // A redirect would carry the token to wherever it points.
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
