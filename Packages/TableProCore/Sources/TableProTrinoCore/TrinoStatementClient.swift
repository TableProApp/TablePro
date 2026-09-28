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
    private var running: [ObjectIdentifier: TrinoRunningStatement] = [:]

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

    /// The paging loop runs in an unstructured task, so terminating the stream has to cancel it
    /// explicitly. Without that the loop keeps fetching pages nobody reads, and its own
    /// `abortIfCancelled` never fires because nothing ever cancels the task it runs in.
    public func executeStreamed(_ sql: String) -> AsyncThrowingStream<TrinoStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let client = self
            let statementTask = Task {
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
            continuation.onTermination = { @Sendable _ in statementTask.cancel() }
        }
    }

    /// Stops every statement running on this client, not only the one that started last: the app
    /// runs sidebar and autocomplete reads on the same client while a query runs. Each statement
    /// is told to stop, its request in flight is cancelled, and Trino gets one DELETE for it.
    public func cancel() {
        let statements = lock.withLock { Array(running.values) }
        statements.forEach { $0.markCancelled() }
        transport.cancelAll()
        statements.compactMap { $0.claimRelease() }.forEach(fireDelete)
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
        guard let statementURL = config.statementURL else {
            throw TrinoError.invalidConfiguration("Invalid Trino server URL")
        }
        if let credential = config.plaintextCredential {
            throw TrinoError.credentialsRequireTLS(credential)
        }
        let statement = TrinoRunningStatement()
        lock.withLock { running[ObjectIdentifier(statement)] = statement }
        defer { lock.withLock { running[ObjectIdentifier(statement)] = nil } }

        do {
            return try await drive(statement, url: statementURL, sql: sql, onColumns: onColumns, onPage: onPage)
        } catch {
            releaseIfCancelled(statement)
            throw error
        }
    }

    private func drive(
        _ statement: TrinoRunningStatement,
        url statementURL: URL,
        sql: String,
        onColumns: ([TrinoColumn]) -> Void,
        onPage: ([[TrinoValue]]) -> Void
    ) async throws -> StatementOutcome {
        var httpResponse = try await sendWithRetry(
            makeRequest(method: .post, url: statementURL, headers: initialHeaders(), body: Data(sql.utf8)),
            for: statement
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
            statement.advance(to: uri)
            let nextURL = try followURL(uri)
            httpResponse = try await sendWithRetry(
                makeRequest(method: .get, url: nextURL, headers: followHeaders()),
                for: statement
            )
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

    private func abortIfCancelled(_ statement: TrinoRunningStatement) throws {
        guard statement.isCancelled || Task.isCancelled else { return }
        throw TrinoError.cancelled
    }

    private func releaseIfCancelled(_ statement: TrinoRunningStatement) {
        guard statement.isCancelled || Task.isCancelled, let uri = statement.claimRelease() else { return }
        fireDelete(uri)
    }

    private func sendWithRetry(
        _ request: TrinoHTTPRequest,
        for statement: TrinoRunningStatement
    ) async throws -> TrinoHTTPResponse {
        var attempt = 0
        while true {
            try abortIfCancelled(statement)
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200...299:
                return response
            case 502, 503, 504:
                attempt += 1
                guard attempt <= Self.maxTransientRetries else {
                    throw TrinoError.httpStatus(code: response.statusCode, body: readableBody(response))
                }
                Self.logger.debug("Trino transient \(response.statusCode, privacy: .public), retry \(attempt)")
                try await sleepBackoff(attempt: attempt, retryAfter: nil)
            case 429:
                attempt += 1
                guard attempt <= Self.maxTransientRetries else {
                    throw TrinoError.httpStatus(code: 429, body: readableBody(response))
                }
                try await sleepBackoff(attempt: attempt, retryAfter: response.retryAfterSeconds())
            case 300...399:
                throw TrinoRedirectPolicy.refusal(for: response, requestURL: request.url, useTLS: config.useTLS)
            case 401, 403:
                throw authenticationFailure(response)
            default:
                throw failure(for: response)
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
        guard let url = try? followURL(uri) else { return }
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

    private func followURL(_ uri: String) throws -> URL {
        guard let url = URL(string: uri) else {
            throw TrinoError.invalidResponse("Trino returned an invalid nextUri")
        }
        guard config.useTLS, url.scheme?.lowercased() != "https" else { return url }
        throw TrinoError.invalidResponse(
            "Trino answered an HTTPS request with a plain http:// address, so it was not followed. "
                + "A coordinator behind a TLS proxy needs http-server.process-forwarded=true."
        )
    }

    private func failure(for response: TrinoHTTPResponse) -> TrinoError {
        let body = bodyText(response)
        let readable = TrinoResponseText.readable(body)
        guard !config.useTLS, TrinoResponseText.isPlaintextRejection(statusCode: response.statusCode, body: body) else {
            return .httpStatus(code: response.statusCode, body: readable)
        }
        return .tlsHandshakeFailed(kind: .serverRejectedPlaintext, serverMessage: readable)
    }

    private func authenticationFailure(_ response: TrinoHTTPResponse) -> TrinoError {
        let message = authMessage(response)
        guard response.clientCertificateRequest == .unanswered, config.auth == .none else {
            return .authenticationFailed(message)
        }
        return .tlsHandshakeFailed(kind: .clientCertificateRequired, serverMessage: message)
    }

    private func authMessage(_ response: TrinoHTTPResponse) -> String {
        let body = readableBody(response)
        return body.isEmpty ? "Authentication failed" : body
    }

    private func readableBody(_ response: TrinoHTTPResponse) -> String {
        TrinoResponseText.readable(bodyText(response))
    }

    private func bodyText(_ response: TrinoHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class TrinoRunningStatement: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var released = false
    private var nextUri: String?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }

    func advance(to uri: String) {
        lock.withLock { nextUri = uri }
    }

    func claimRelease() -> String? {
        lock.withLock {
            guard !released, let nextUri else { return nil }
            released = true
            return nextUri
        }
    }
}
