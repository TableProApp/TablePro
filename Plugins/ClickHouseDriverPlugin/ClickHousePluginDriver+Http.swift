//
//  ClickHousePluginDriver+Http.swift
//  ClickHouseDriverPlugin
//

import Foundation
import os
import TableProPluginKit

extension ClickHousePluginDriver {
    // MARK: - Private HTTP Layer

    func executeRaw(_ query: String, queryId: String? = nil) async throws -> CHQueryResult {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        if let queryId {
            _lastQueryId = queryId
        }
        lock.unlock()

        var request = try buildRequest(query: query, database: database, queryId: queryId)
        request.timeoutInterval = _queryTimeout.requestTimeoutInterval
        return try await perform(request: request, session: session)
    }

    func executeRawWithParams(_ query: String, params: [String: String?], queryId: String? = nil) async throws -> CHQueryResult {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        if let queryId {
            _lastQueryId = queryId
        }
        lock.unlock()

        var request = try buildRequest(query: query, database: database, queryId: queryId, params: params)
        request.timeoutInterval = _queryTimeout.requestTimeoutInterval
        return try await perform(request: request, session: session)
    }

    private func perform(request: URLRequest, session: URLSession) async throws -> CHQueryResult {
        let (data, response) = try await send(request: request, session: session)

        lock.lock()
        currentTask = nil
        lock.unlock()

        let httpResponse = response as? HTTPURLResponse
        if let httpResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            let exceptionCode = httpResponse.value(forHTTPHeaderField: "X-ClickHouse-Exception-Code") ?? "none"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode) exception \(exceptionCode): \(body)")
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let outcome = ClickHouseResponseClassifier.classify(
            headers: Self.headerFields(httpResponse),
            body: data
        )
        return CHQueryResult(
            columns: outcome.columns,
            columnTypeNames: outcome.columnTypeNames,
            rows: outcome.rows,
            affectedRows: outcome.affectedRows,
            isTruncated: outcome.isTruncated
        )
    }

    private func send(request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: ClickHouseError(message: "Empty response from server"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }

                self.lock.lock()
                self.currentTask = task
                self.lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.currentTask?.cancel()
            self.currentTask = nil
            self.lock.unlock()
        }
    }

    private static func headerFields(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            fields[name] = text
        }
        return fields
    }

    func buildRequest(query: String, database: String, queryId: String? = nil, params: [String: String?]? = nil) throws -> URLRequest {
        let useTLS = config.ssl.isEnabled

        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"

        var queryItems = [URLQueryItem]()
        if !database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: database))
        }
        if let queryId {
            queryItems.append(URLQueryItem(name: "query_id", value: queryId))
        }
        queryItems.append(URLQueryItem(name: "send_progress_in_http_headers", value: "1"))
        queryItems.append(contentsOf: ClickHouseResponseClassifier.transportQueryItems(
            supportsWriteExceptionSetting: ClickHouseCapabilities.parse(serverVersion).hasWriteExceptionInOutputFormatSetting
        ))
        if let params {
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                queryItems.append(URLQueryItem(name: "param_\(key)", value: value))
            }
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ClickHouseError(message: "Failed to construct request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        if let authorization = ClickHouseCredentials.basicAuthorizationHeader(
            username: config.username,
            password: config.password
        ) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ";+$", with: "", options: .regularExpression)
        request.httpBody = trimmedQuery.data(using: .utf8)

        return request
    }

    /// Convert `?` placeholders to `{p1:String}` and build parameter map for ClickHouse HTTP params.
    static func buildClickHouseParams(
        query: String,
        parameters: [PluginCellValue]
    ) -> (String, [String: String?]) {
        var converted = ""
        var paramIndex = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for char in query {
            if isEscaped {
                isEscaped = false
                converted.append(char)
                continue
            }
            if char == "\\" && (inSingleQuote || inDoubleQuote) {
                isEscaped = true
                converted.append(char)
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            if char == "?" && !inSingleQuote && !inDoubleQuote && paramIndex < parameters.count {
                paramIndex += 1
                converted.append("{p\(paramIndex):String}")
            } else {
                converted.append(char)
            }
        }

        var paramMap: [String: String?] = [:]
        for i in 0..<paramIndex where i < parameters.count {
            switch parameters[i] {
            case .null:
                paramMap["p\(i + 1)"] = nil
            case .text(let s):
                paramMap["p\(i + 1)"] = s
            case .bytes(let d):
                paramMap["p\(i + 1)"] = "0x" + d.map { String(format: "%02X", $0) }.joined()
            }
        }

        return (converted, paramMap)
    }
}
