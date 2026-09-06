//
//  TypesenseConnection.swift
//  TypesenseDriverPlugin
//
//  HTTP client for the Typesense REST API.
//

import Foundation
import os
import TableProPluginKit

internal enum TypesenseError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serverError(String)
    case authFailed(String)
    case requestCancelled
    case invalidResponse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Typesense")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .serverError(let detail):
            return String(format: String(localized: "Typesense error: %@"), detail)
        case .authFailed(let detail):
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        case .invalidResponse(let detail):
            return String(format: String(localized: "Invalid response: %@"), detail)
        case .unsupported(let detail):
            return detail
        }
    }
}

internal struct TypesenseResponse {
    let statusCode: Int
    let json: Any?
    let rawText: String

    var isSuccess: Bool { (200 ..< 300).contains(statusCode) }
}

internal final class TypesenseConnection: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var _session: URLSession?
    private var _currentTask: URLSessionDataTask?
    private var _serverVersion: String?
    private let queryTimeout = HttpQueryTimeoutBox()

    private let baseURL: URL
    private let apiKey: String
    private let skipTLSVerify: Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "TypesenseConnection")
    private static let apiKeyHeader = "X-TYPESENSE-API-KEY"

    var serverVersion: String? { lock.withLock { _serverVersion } }

    init(config: DriverConnectionConfig) throws {
        let scheme = config.ssl.isEnabled ? "https" : "http"
        let host = config.host.isEmpty ? "localhost" : config.host
        let port = config.port > 0 ? config.port : TypesensePlugin.defaultPort
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw TypesenseError.connectionFailed("Invalid host: \(host):\(port)")
        }
        self.baseURL = url
        self.apiKey = config.additionalFields[TypesensePlugin.apiKeyFieldId] ?? config.password
        self.skipTLSVerify = (config.additionalFields[TypesensePlugin.skipTLSVerifyFieldId] == "true")
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
    }

    func setQueryTimeout(_ seconds: Int) {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        sessionConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        lock.withLock { _session = session }

        let response = try await request(method: "GET", path: "/debug")
        guard response.isSuccess else { throw mapError(response, fallback: "Connection check failed") }
        if let json = response.json as? [String: Any], let version = json["version"] as? String {
            lock.withLock { _serverVersion = version }
        }
    }

    func disconnect() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
            _session?.finishTasksAndInvalidate()
            _session = nil
        }
    }

    /// `/health` needs no key, so a ping that used it would keep reporting a healthy connection
    /// after the key was revoked. `/collections` is the cheapest call that proves both.
    func ping() async throws {
        let response = try await request(method: "GET", path: "/collections")
        guard response.isSuccess else { throw mapError(response, fallback: "Ping failed") }
    }

    func cancelCurrentRequest() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
        }
    }

    // MARK: - API Operations

    func collections() async throws -> [TypesenseCollection] {
        let response = try await request(method: "GET", path: "/collections")
        guard response.isSuccess else { throw mapError(response, fallback: "Failed to list collections") }
        return TypesenseSchema.collections(from: response.json)
    }

    func collection(_ name: String) async throws -> TypesenseCollection {
        let response = try await request(method: "GET", path: "/collections/\(TypesensePathEncoding.segment(name))")
        guard response.isSuccess, let json = response.json as? [String: Any],
              let collection = TypesenseSchema.collection(from: json)
        else { throw mapError(response, fallback: "Failed to fetch the collection schema") }
        return collection
    }

    func collectionJSON(_ name: String) async throws -> String {
        let response = try await request(method: "GET", path: "/collections/\(TypesensePathEncoding.segment(name))")
        guard response.isSuccess else { throw mapError(response, fallback: "Failed to fetch the collection schema") }
        return response.rawText
    }

    /// Every search goes through `multi_search`, which takes its searches in a body and so has no
    /// URL length ceiling. Results come back in request order, one per search.
    func multiSearch(_ searches: [[String: Any]]) async throws -> [[String: Any]] {
        guard !searches.isEmpty else { return [] }
        let body = try serialize(TypesenseQueryBuilder.multiSearchBody(searches))
        let response = try await request(method: "POST", path: "/multi_search", body: body)
        guard response.isSuccess, let json = response.json as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { throw mapError(response, fallback: "Search failed") }

        if let failure = results.first(where: { $0["error"] is String }) {
            throw searchError(failure)
        }
        return results
    }

    // MARK: - Raw Request

    @discardableResult
    func request(method: String, path: String, body: String? = nil) async throws -> TypesenseResponse {
        let session: URLSession = try lock.withLock {
            guard let session = _session else { throw TypesenseError.notConnected }
            return session
        }

        guard let url = TypesensePathEncoding.resolve(path, against: baseURL) else {
            throw TypesenseError.invalidResponse(
                String(format: String(localized: "Not a path on this server: %@"), path)
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.uppercased()
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
        if let body {
            urlRequest.httpBody = Data(body.utf8)
        }
        urlRequest.timeoutInterval = queryTimeout.requestTimeoutInterval

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
                self?.lock.withLock { self?._currentTask = nil }
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: TypesenseError.requestCancelled)
                    } else {
                        continuation.resume(throwing: TypesenseError.connectionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: TypesenseError.invalidResponse("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            self.lock.withLock { self._currentTask = task }
            task.resume()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TypesenseError.invalidResponse("Not an HTTP response")
        }

        return TypesenseResponse(
            statusCode: httpResponse.statusCode,
            json: try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            rawText: String(data: data, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Helpers

    func serialize(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw TypesenseError.invalidResponse("Invalid request body")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }


    /// A `multi_search` answers 200 and reports a per-search failure in the result, so the
    /// transport status never carries it.
    private func searchError(_ result: [String: Any]) -> TypesenseError {
        let message = (result["error"] as? String) ?? "Search failed"
        let code = (result["code"] as? Int) ?? 0
        return code == 401 || code == 403 ? .authFailed(message) : .serverError(message)
    }

    func mapError(_ response: TypesenseResponse, fallback: String) -> TypesenseError {
        let reason = self.reason(from: response)
        if response.statusCode == 401 || response.statusCode == 403 {
            return .authFailed(reason ?? fallback)
        }
        return .serverError(reason ?? "HTTP \(response.statusCode): \(fallback)")
    }

    private func reason(from response: TypesenseResponse) -> String? {
        guard let json = response.json as? [String: Any] else {
            return response.rawText.isEmpty ? nil : response.rawText
        }
        return json["message"] as? String
    }
}

extension TypesenseConnection: URLSessionDelegate {
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
}
