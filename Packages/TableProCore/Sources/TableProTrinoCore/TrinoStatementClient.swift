import Foundation
import os

public enum TrinoStreamElement: Sendable {
    case columns([TrinoColumnDescriptor])
    case rows([[TrinoValue]])
}

public final class TrinoStatementClient: @unchecked Sendable {
    private let transport: TrinoTransport
    private let config: TrinoClientConfig
    private let session: TrinoSessionState
    private let lock = NSLock()
    private var _cancelled = false
    private var _currentNextUri: String?

    private static let maxTransientRetries = 5
    private static let logger = Logger(subsystem: "com.TablePro", category: "TrinoStatementClient")

    public init(transport: TrinoTransport, config: TrinoClientConfig, session: TrinoSessionState) {
        self.transport = transport
        self.config = config
        self.session = session
    }

    public func execute(_ sql: String) async throws -> TrinoResultSet {
        var columns: [TrinoColumn] = []
        var rows: [[TrinoValue]] = []
        let outcome = try await runStatement(
            sql,
            onColumns: { columns = $0 },
            onPage: { rows.append(contentsOf: $0) }
        )
        return TrinoResultSet(
            columns: descriptors(from: columns),
            rows: rows,
            updateType: outcome.updateType,
            updateCount: outcome.updateCount,
            queryId: outcome.queryId
        )
    }

    public func executeStreamed(_ sql: String) -> AsyncThrowingStream<TrinoStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let client = self
            Task {
                do {
                    _ = try await client.runStatement(
                        sql,
                        onColumns: { continuation.yield(.columns(client.descriptors(from: $0))) },
                        onPage: { continuation.yield(.rows($0)) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel() {
        let uri = lock.withLock { () -> String? in
            _cancelled = true
            return _currentNextUri
        }
        if let uri {
            fireDelete(uri)
        }
    }

    private struct StatementOutcome {
        let updateType: String?
        let updateCount: Int?
        let queryId: String
    }

    private func runStatement(
        _ sql: String,
        onColumns: ([TrinoColumn]) -> Void,
        onPage: ([[TrinoValue]]) -> Void
    ) async throws -> StatementOutcome {
        lock.withLock {
            _cancelled = false
            _currentNextUri = nil
        }
        guard let statementURL = config.statementURL else {
            throw TrinoError.invalidConfiguration("Invalid Trino server URL")
        }

        var httpResponse = try await sendWithRetry(
            makeRequest(method: .post, url: statementURL, headers: initialHeaders(), body: Data(sql.utf8))
        )
        var results = try decode(httpResponse)
        session.apply(responseHeaders: httpResponse.headers, protocolHeaders: config.protocolHeaders)
        if let error = results.error {
            throw TrinoError.query(error)
        }

        var columns = results.columns
        var columnsEmitted = false
        if let columns {
            onColumns(columns)
            columnsEmitted = true
        }
        emitRows(results, columns: columns, onPage: onPage)
        var updateType = results.updateType
        var updateCount = results.updateCount
        let queryId = results.id
        var nextUri = results.nextUri

        while let uri = nextUri {
            try abortIfCancelled(currentUri: uri)
            lock.withLock { _currentNextUri = uri }
            guard let nextURL = URL(string: uri) else {
                throw TrinoError.invalidResponse("Trino returned an invalid nextUri")
            }
            httpResponse = try await sendWithRetry(makeRequest(method: .get, url: nextURL, headers: followHeaders()))
            results = try decode(httpResponse)
            session.apply(responseHeaders: httpResponse.headers, protocolHeaders: config.protocolHeaders)
            if let error = results.error {
                throw TrinoError.query(error)
            }
            if columns == nil {
                columns = results.columns
            }
            if !columnsEmitted, let columns {
                onColumns(columns)
                columnsEmitted = true
            }
            emitRows(results, columns: columns, onPage: onPage)
            if let type = results.updateType {
                updateType = type
            }
            if let count = results.updateCount {
                updateCount = count
            }
            nextUri = results.nextUri
        }

        lock.withLock { _currentNextUri = nil }
        return StatementOutcome(updateType: updateType, updateCount: updateCount, queryId: queryId)
    }

    private func emitRows(_ results: TrinoQueryResults, columns: [TrinoColumn]?, onPage: ([[TrinoValue]]) -> Void) {
        guard let data = results.data, let columns, !data.isEmpty else { return }
        var page: [[TrinoValue]] = []
        page.reserveCapacity(data.count)
        for row in data {
            var decoded: [TrinoValue] = []
            decoded.reserveCapacity(columns.count)
            for (index, value) in row.enumerated() {
                let category = index < columns.count ? columns[index].category : .scalar
                decoded.append(TrinoValueDecoder.decode(value, category: category))
            }
            page.append(decoded)
        }
        onPage(page)
    }

    private func descriptors(from columns: [TrinoColumn]) -> [TrinoColumnDescriptor] {
        columns.map {
            TrinoColumnDescriptor(name: $0.name, typeName: $0.type, category: $0.category)
        }
    }

    private func abortIfCancelled(currentUri: String) throws {
        let cancelled = lock.withLock { _cancelled } || Task.isCancelled
        guard cancelled else { return }
        fireDelete(currentUri)
        throw TrinoError.cancelled
    }

    private func sendWithRetry(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        var attempt = 0
        while true {
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200...299:
                return response
            case 502, 503, 504:
                attempt += 1
                guard attempt <= Self.maxTransientRetries else {
                    throw TrinoError.httpStatus(code: response.statusCode, body: bodyText(response))
                }
                Self.logger.debug("Trino transient \(response.statusCode, privacy: .public), retry \(attempt)")
                try await sleepBackoff(attempt: attempt, retryAfter: nil)
            case 429:
                attempt += 1
                guard attempt <= Self.maxTransientRetries else {
                    throw TrinoError.httpStatus(code: 429, body: bodyText(response))
                }
                try await sleepBackoff(attempt: attempt, retryAfter: response.retryAfterSeconds())
            case 401, 403:
                throw TrinoError.authenticationFailed(authMessage(response))
            default:
                throw TrinoError.httpStatus(code: response.statusCode, body: bodyText(response))
            }
        }
    }

    private func sleepBackoff(attempt: Int, retryAfter: Double?) async throws {
        let seconds: Double
        if let retryAfter, retryAfter > 0 {
            seconds = min(retryAfter, 10)
        } else {
            seconds = min(0.05 * Double(attempt) + 0.05, 1.0)
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func decode(_ response: TrinoHTTPResponse) throws -> TrinoQueryResults {
        do {
            return try JSONDecoder().decode(TrinoQueryResults.self, from: response.body)
        } catch {
            throw TrinoError.invalidResponse("Could not decode the Trino response")
        }
    }

    private func fireDelete(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        let request = makeRequest(method: .delete, url: url, headers: followHeaders())
        let transport = self.transport
        Task.detached { _ = try? await transport.send(request) }
    }

    private func makeRequest(
        method: TrinoHTTPRequest.Method,
        url: URL,
        headers: [String: String],
        body: Data? = nil
    ) -> TrinoHTTPRequest {
        TrinoHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeoutSeconds: config.requestTimeoutSeconds
        )
    }

    private func initialHeaders() -> [String: String] {
        let protocolHeaders = config.protocolHeaders
        var headers: [String: String] = [:]
        if !config.user.isEmpty {
            headers[protocolHeaders.user] = config.user
        }
        if !config.source.isEmpty {
            headers[protocolHeaders.source] = config.source
        }
        if let catalog = session.catalog, !catalog.isEmpty {
            headers[protocolHeaders.catalog] = catalog
        }
        if let schema = session.schema, !schema.isEmpty {
            headers[protocolHeaders.schema] = schema
        }
        if let timeZone = config.timeZone, !timeZone.isEmpty {
            headers[protocolHeaders.timeZone] = timeZone
        }
        let sessionProperties = session.sessionPropertyHeaderValue()
        if !sessionProperties.isEmpty {
            headers[protocolHeaders.session] = sessionProperties
        }
        let prepared = session.preparedStatementHeaderValue()
        if !prepared.isEmpty {
            headers[protocolHeaders.preparedStatement] = prepared
        }
        if let transactionId = session.transactionId, !transactionId.isEmpty {
            headers[protocolHeaders.transactionId] = transactionId
        }
        if !config.clientTags.isEmpty {
            headers[protocolHeaders.clientTags] = config.clientTags.joined(separator: ",")
        }
        headers[protocolHeaders.clientCapabilities] = "PARAMETRIC_DATETIME"
        headers["Content-Type"] = "text/plain; charset=utf-8"
        if let authorization = config.authorizationHeader {
            headers["Authorization"] = authorization
        }
        return headers
    }

    private func followHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let authorization = config.authorizationHeader {
            headers["Authorization"] = authorization
        }
        return headers
    }

    private func authMessage(_ response: TrinoHTTPResponse) -> String {
        let body = bodyText(response)
        return body.isEmpty ? "Authentication failed" : body
    }

    private func bodyText(_ response: TrinoHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
