//
//  ClickHousePluginDriver+Http.swift
//  ClickHouseDriverPlugin
//

import Foundation
import os
import TableProPluginKit

nonisolated extension ClickHousePluginDriver {
    // MARK: - Private HTTP Layer

    var executionTimeLimit: Int? {
        lock.withLock { acceptedExecutionTimeLimit }
    }

    func executeRaw(
        _ query: String,
        queryId: String? = nil,
        requestTimeout: TimeInterval? = nil
    ) async throws -> CHQueryResult {
        try await sendStatement(
            query,
            queryId: queryId,
            params: nil,
            executionTimeLimit: executionTimeLimit,
            requestTimeout: requestTimeout
        )
    }

    func executeRawWithParams(_ query: String, params: [String: String?], queryId: String? = nil) async throws -> CHQueryResult {
        try await sendStatement(query, queryId: queryId, params: params, executionTimeLimit: executionTimeLimit)
    }

    func sendStatement(
        _ query: String,
        queryId: String?,
        params: [String: String?]?,
        executionTimeLimit: Int?,
        requestTimeout: TimeInterval? = nil
    ) async throws -> CHQueryResult {
        let (session, database) = try lock.withLock { () throws -> (URLSession, String) in
            guard let session = self.session else { throw ClickHouseError.notConnected }
            let database = _currentDatabase
            if let queryId {
                _lastQueryId = queryId
            }
            return (session, database)
        }

        var request = try buildRequest(
            query: query,
            database: database,
            queryId: queryId,
            executionTimeLimit: executionTimeLimit,
            shape: .buffered(parameters: params)
        )
        request.timeoutInterval = requestTimeout ?? _queryTimeout.requestTimeoutInterval
        return try await perform(request: request, session: session)
    }

    static func executionTimeLimitItems(_ seconds: Int?) -> [URLQueryItem] {
        guard let seconds, seconds > 0 else { return [] }
        return [URLQueryItem(name: "max_execution_time", value: String(seconds))]
    }

    private func perform(request: URLRequest, session: URLSession) async throws -> CHQueryResult {
        let (data, response) = try await send(request: request, session: session)

        lock.withLock { currentTask = nil }

        let httpResponse = response as? HTTPURLResponse
        if let httpResponse, Self.isFailure(httpResponse) {
            let body = String(decoding: data, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            let exceptionCode = httpResponse.value(forHTTPHeaderField: Self.exceptionCodeHeader) ?? "none"
            Self.logger.error("ClickHouse HTTP \(httpResponse.statusCode) exception \(exceptionCode): \(body)")
            throw ClickHouseError.httpFailure(statusCode: httpResponse.statusCode, body: body)
        }

        let headers = Self.headerFields(httpResponse)
        let outcome = ClickHouseResponseClassifier.classify(
            headers: headers,
            body: data
        )
        return CHQueryResult(
            columns: outcome.columns,
            columnTypeNames: outcome.columnTypeNames,
            rows: outcome.rows,
            affectedRows: outcome.affectedRows,
            isTruncated: outcome.isTruncated,
            serverElapsed: ClickHouseSummaryParser.parse(headers: headers)?.elapsed
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

    static let exceptionCodeHeader = "X-ClickHouse-Exception-Code"

    /// With `send_progress_in_http_headers` the status goes out with the first progress header, so
    /// a query that fails after it answers HTTP 200 and names the failure in this header.
    static func isFailure(_ response: HTTPURLResponse) -> Bool {
        response.statusCode >= 400 || response.value(forHTTPHeaderField: exceptionCodeHeader) != nil
    }

    static func headerFields(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            fields[name] = text
        }
        return fields
    }

    /// Every request goes through here, so a URL setting is sent the same way on every path and
    /// only when the server profile says this user may change it.
    func buildRequest(
        query: String,
        database: String,
        queryId: String?,
        executionTimeLimit: Int?,
        shape: ClickHouseResponseShape
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = config.ssl.isEnabled ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"
        components.queryItems = Self.queryItems(
            database: database,
            queryId: queryId,
            executionTimeLimit: executionTimeLimit,
            shape: shape,
            profile: serverProfile
        )

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
        /// 25.10 compresses by default, and a compressed stream that fails partway is cut mid-row
        /// with the exception text gone. URLSession asks for gzip unless told otherwise.
        if case .streamed = shape {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }

        request.httpBody = Self.withoutTrailingSemicolons(query).data(using: .utf8)
        return request
    }

    static func queryItems(
        database: String,
        queryId: String?,
        executionTimeLimit: Int?,
        shape: ClickHouseResponseShape,
        profile: ClickHouseServerProfile
    ) -> [URLQueryItem] {
        var items = [URLQueryItem]()
        if !database.isEmpty {
            items.append(URLQueryItem(name: "database", value: database))
        }
        if let queryId {
            items.append(URLQueryItem(name: "query_id", value: queryId))
        }
        items.append(URLQueryItem(name: "default_format", value: ClickHouseResponseClassifier.requestedFormat))
        items.append(contentsOf: executionTimeLimitItems(executionTimeLimit))
        /// A user-written `FORMAT JSON` or `XML` that fails is otherwise wrapped in that format,
        /// or sent as an empty body on 23.9.
        if let item = profile.queryItem(.httpWriteExceptionInOutputFormat, "0") {
            items.append(item)
        }

        switch shape {
        case .buffered(let parameters):
            items.append(URLQueryItem(name: "wait_end_of_query", value: "1"))
            if let item = profile.queryItem(.sendProgressInHTTPHeaders, "1") {
                items.append(item)
            }
            for (key, value) in (parameters ?? [:]).sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: "param_\(key)", value: value))
            }
        case .streamed(let rowCap):
            guard let rowCap else { break }
            /// The bound rides as an HTTP setting so the SQL in the body stays exactly what the
            /// user wrote. One row past the cap, so a full page can be told from a truncated one.
            /// `max_result_rows` alone makes an overflow throw, so it goes out only with `break`.
            /// Held on the server, a capped read costs nothing, since the collector waits for the
            /// whole page anyway, and a failure then arrives as a status on every version. Without
            /// the cap the server would hold the whole result, so the reader stops at the cap and
            /// the body is checked for an exception instead.
            if let rows = profile.queryItem(.maxResultRows, String(rowCap + 1)),
               let mode = profile.queryItem(.resultOverflowMode, "break") {
                items.append(contentsOf: [rows, mode, URLQueryItem(name: "wait_end_of_query", value: "1")])
            }
            if let item = profile.queryItem(.cancelHTTPReadonlyQueriesOnClientClose, "1") {
                items.append(item)
            }
        }
        return items
    }

    static func withoutTrailingSemicolons(_ query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

/// How the server hands a result back.
nonisolated enum ClickHouseResponseShape: Equatable {
    /// The server holds the whole result until the query ends, so a failure is an HTTP status and
    /// `X-ClickHouse-Summary` carries the totals.
    case buffered(parameters: [String: String?]?)
    /// Rows arrive through the chunk reader. Unbounded, they come as the server produces them, so
    /// a failure after the first block arrives in the body under HTTP 200: `wait_end_of_query`
    /// would hold a whole export on the server.
    case streamed(rowCap: Int?)
}
