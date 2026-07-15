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
        let isSelect = Self.isSelectLikeQuery(query)

        let (data, response) = try await withTaskCancellationHandler {
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

        lock.lock()
        currentTask = nil
        lock.unlock()

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode): \(body)")
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if isSelect {
            return parseTabSeparatedResponse(data)
        }

        return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
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
        let isSelect = Self.isSelectLikeQuery(query)

        let (data, response) = try await withTaskCancellationHandler {
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

        lock.lock()
        currentTask = nil
        lock.unlock()

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode): \(body)")
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if isSelect {
            return parseTabSeparatedResponse(data)
        }

        return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
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
        if let params {
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                queryItems.append(URLQueryItem(name: "param_\(key)", value: value))
            }
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

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

        if Self.isSelectLikeQuery(trimmedQuery) {
            request.httpBody = (trimmedQuery + " FORMAT TabSeparatedWithNamesAndTypes").data(using: .utf8)
        } else {
            request.httpBody = trimmedQuery.data(using: .utf8)
        }

        return request
    }

    static func isSelectLikeQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = trimmed.split(separator: " ", maxSplits: 1).first else {
            return false
        }
        return selectPrefixes.contains(firstWord.uppercased())
    }

    func parseTabSeparatedResponse(_ data: Data) -> CHQueryResult {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
        }

        let lines = text.components(separatedBy: "\n")

        guard lines.count >= 2 else {
            return CHQueryResult(columns: [], columnTypeNames: [], rows: [], affectedRows: 0, isTruncated: false)
        }

        let columns = lines[0].components(separatedBy: "\t")
        let columnTypes = lines[1].components(separatedBy: "\t")

        var rows: [[PluginCellValue]] = []
        var truncated = false
        for i in 2..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }

            let fields = line.components(separatedBy: "\t")
            let row: [PluginCellValue] = fields.map { field in
                if field == "\\N" {
                    return .null
                }
                return .text(Self.unescapeTsvField(field))
            }
            rows.append(row)
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
        }

        return CHQueryResult(
            columns: columns,
            columnTypeNames: columnTypes,
            rows: rows,
            affectedRows: rows.count,
            isTruncated: truncated
        )
    }

    static func unescapeTsvField(_ field: String) -> String {
        var result = ""
        result.reserveCapacity((field as NSString).length)
        var iterator = field.makeIterator()

        while let char = iterator.next() {
            if char == "\\" {
                if let next = iterator.next() {
                    switch next {
                    case "\\": result.append("\\")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    default:
                        result.append("\\")
                        result.append(next)
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(char)
            }
        }

        return result
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
