//
//  R2SQLURLSessionTransport.swift
//  TablePro
//

import Foundation
import TableProR2SQLCore

final class URLSessionR2SQLTransport: NSObject, R2SQLTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: URLSessionDataTask?

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        super.init()
    }

    func cancelInFlight() {
        let task = lock.withLock { inFlight }
        task?.cancel()
    }

    func send(_ request: R2SQLHTTPRequest) async throws -> R2SQLHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = TimeInterval(request.timeoutSeconds)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: R2SQLError.cancelled)
                    } else {
                        continuation.resume(throwing: R2SQLError.transport(error.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: R2SQLError.transport("Empty response from R2 SQL"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            lock.withLock { inFlight = task }
            task.resume()
        }

        lock.withLock { inFlight = nil }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw R2SQLError.transport("Response was not HTTP")
        }
        return R2SQLHTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }
}
