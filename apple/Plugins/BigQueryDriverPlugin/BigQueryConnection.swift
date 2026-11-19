import Foundation
import os
import TableProGoogleCloud
import TableProLogRedaction
import TableProPluginKit

internal struct BQTableFieldSchema: Codable, Sendable {
    let name: String
    let type: String
    let mode: String?
    let description: String?
    let fields: [BQTableFieldSchema]?
}

internal struct BQTableSchema: Codable, Sendable {
    let fields: [BQTableFieldSchema]?
}

internal struct BQTableResource: Codable, Sendable {
    let tableReference: BQTableReference?
    let schema: BQTableSchema?
    let numRows: String?
    let numBytes: String?
    let type: String?
    let description: String?
    let creationTime: String?
    let lastModifiedTime: String?
    let clustering: BQClustering?
    let timePartitioning: BQTimePartitioning?
    let rangePartitioning: BQRangePartitioning?
    let labels: [String: String]?
    let expirationTime: String?
    let friendlyName: String?
    let tableConstraints: BQTableConstraints?

    var primaryKeyColumns: [String] {
        tableConstraints?.primaryKey?.columns ?? []
    }

    struct BQTableConstraints: Codable, Sendable {
        let primaryKey: BQPrimaryKey?
    }

    struct BQPrimaryKey: Codable, Sendable {
        let columns: [String]?
    }

    struct BQTableReference: Codable, Sendable {
        let projectId: String?
        let datasetId: String?
        let tableId: String?
    }

    struct BQClustering: Codable, Sendable {
        let fields: [String]?
    }

    struct BQTimePartitioning: Codable, Sendable {
        let type: String?
        let field: String?
    }

    struct BQRangePartitioning: Codable, Sendable {
        let field: String?
        let range: BQRangeDefinition?
    }

    struct BQRangeDefinition: Codable, Sendable {
        let start: String?
        let interval: String?
        let end: String?
    }
}

internal struct BQDatasetListResponse: Codable, Sendable {
    let datasets: [BQDatasetEntry]?
    let nextPageToken: String?

    struct BQDatasetEntry: Codable, Sendable {
        let datasetReference: BQDatasetReference
        let friendlyName: String?
        let location: String?
    }

    struct BQDatasetReference: Codable, Sendable {
        let datasetId: String
        let projectId: String?
    }
}

internal struct BQTableListResponse: Codable, Sendable {
    let tables: [BQTableEntry]?
    let nextPageToken: String?

    struct BQTableEntry: Codable, Sendable {
        let tableReference: BQTableReference
        let type: String?

        struct BQTableReference: Codable, Sendable {
            let tableId: String
            let datasetId: String?
            let projectId: String?
        }
    }
}

internal struct BQJobRequest: Codable, Sendable {
    let jobReference: BQJobRequestReference?
    let configuration: BQJobConfiguration

    struct BQJobRequestReference: Codable, Sendable {
        let projectId: String
        let location: String?
    }

    struct BQJobConfiguration: Codable, Sendable {
        let query: BQQueryConfig?
        let dryRun: Bool?
        let jobTimeoutMs: String?
    }

    struct BQQueryConfig: Codable, Sendable {
        let query: String
        let useLegacySql: Bool
        let defaultDataset: BQDatasetReference?
        let maximumBytesBilled: String?
        let parameterMode: String?
        let queryParameters: [BigQueryQueryParameter]?
    }

    struct BQDatasetReference: Codable, Sendable {
        let projectId: String
        let datasetId: String
    }
}

internal struct BQJobResponse: Codable, Sendable {
    let jobReference: BQJobReference?
    let status: BQJobStatus?
    let configuration: BQJobResponseConfiguration?
    let statistics: BQJobStatistics?

    struct BQJobReference: Codable, Sendable {
        let projectId: String?
        let jobId: String?
        let location: String?
    }

    struct BQJobStatus: Codable, Sendable {
        let state: String?
        let errorResult: BQErrorProto?
        let errors: [BQErrorProto]?
    }

    struct BQErrorProto: Codable, Sendable {
        let reason: String?
        let location: String?
        let message: String?
    }

    struct BQJobResponseConfiguration: Codable, Sendable {
        let query: BQQueryResponseConfig?
    }

    struct BQQueryResponseConfig: Codable, Sendable {
        let destinationTable: BQTableRef?
    }

    struct BQTableRef: Codable, Sendable {
        let projectId: String?
        let datasetId: String?
        let tableId: String?
    }

    struct BQJobStatistics: Codable, Sendable {
        let totalBytesProcessed: String?
        let query: BQQueryStatistics?
        let startTime: String?
        let endTime: String?

        var elapsed: TimeInterval? {
            guard let start = startTime.flatMap(Double.init),
                  let end = endTime.flatMap(Double.init),
                  end >= start
            else {
                return nil
            }
            return (end - start) / 1_000
        }
    }

    struct BQQueryStatistics: Codable, Sendable {
        let totalBytesProcessed: String?
        let totalBytesBilled: String?
        let cacheHit: Bool?
        let numDmlAffectedRows: String?
        let undeclaredQueryParameters: [BigQueryQueryParameter]?
    }
}

internal struct BQQueryResponse: Codable, Sendable {
    let schema: BQTableSchema?
    let rows: [BQRow]?
    let totalRows: String?
    let pageToken: String?
    let jobComplete: Bool?
    let jobReference: BQJobResponse.BQJobReference?
    let numDmlAffectedRows: String?
    var totalBytesProcessed: String?
    var totalBytesBilled: String?
    var cacheHit: Bool?
    var startTime: String?
    var endTime: String?

    // jobs.query reports what jobs.get reported for a finished job on the answer itself.
    var statistics: BQJobResponse.BQJobStatistics {
        BQJobResponse.BQJobStatistics(
            totalBytesProcessed: totalBytesProcessed,
            query: BQJobResponse.BQQueryStatistics(
                totalBytesProcessed: totalBytesProcessed,
                totalBytesBilled: totalBytesBilled,
                cacheHit: cacheHit,
                numDmlAffectedRows: numDmlAffectedRows,
                undeclaredQueryParameters: nil
            ),
            startTime: startTime,
            endTime: endTime
        )
    }

    struct BQRow: Codable, Sendable {
        let f: [BQCell]?
    }

    struct BQCell: Codable, Sendable {
        let v: BQCellValue?
    }
}

internal enum BQCellValue: Codable, Sendable {
    case string(String)
    case null
    case record(BQRecordValue)
    case array([BQCellValue])

    struct BQRecordValue: Codable, Sendable {
        let f: [BQQueryResponse.BQCell]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let cells = try? container.decode([BQQueryResponse.BQCell].self) {
            self = .array(cells.map { $0.v ?? .null })
            return
        }
        if let record = try? container.decode(BQRecordValue.self) {
            self = .record(record)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .null:
            try container.encodeNil()
        case .record(let record):
            try container.encode(record)
        case .array(let values):
            try container.encode(values.map { BQQueryResponse.BQCell(v: $0) })
        }
    }
}

// A finished statement: its first page, and the job later pages come from when the server made one.
internal struct BQStatementRun: Sendable {
    let firstPage: BQQueryResponse
    let jobId: String?
    let location: String?
    let statistics: BQJobResponse.BQJobStatistics?
}

internal struct BQExecuteResult: Sendable {
    let queryResponse: BQQueryResponse
    let dmlAffectedRows: Int
    let totalBytesProcessed: String?
    let totalBytesBilled: String?
    let cacheHit: Bool?
    let serverElapsed: TimeInterval?

    init(
        queryResponse: BQQueryResponse,
        dmlAffectedRows: Int,
        totalBytesProcessed: String?,
        totalBytesBilled: String? = nil,
        cacheHit: Bool? = nil,
        serverElapsed: TimeInterval? = nil
    ) {
        self.queryResponse = queryResponse
        self.dmlAffectedRows = dmlAffectedRows
        self.totalBytesProcessed = totalBytesProcessed
        self.totalBytesBilled = totalBytesBilled
        self.cacheHit = cacheHit
        self.serverElapsed = serverElapsed
    }
}

internal struct BQErrorResponse: Codable, Sendable {
    let error: BQErrorDetail?

    struct BQErrorDetail: Codable, Sendable {
        let code: Int?
        let message: String?
        let status: String?
        let errors: [BQJobResponse.BQErrorProto]?
    }

    static func apiError(status: Int, data: Data) -> BigQueryError {
        guard let detail = (try? JSONDecoder().decode(BQErrorResponse.self, from: data))?.error else {
            return .api(status: status, message: "", reason: nil)
        }
        return .api(
            status: detail.code ?? status,
            message: detail.message ?? "",
            reason: detail.errors?.first?.reason
        )
    }
}

internal enum BigQueryJobPolling {
    static let doneState = "DONE"
    static let deadlineGraceSeconds = 30

    static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let milliseconds = min(500 * pow(2.0, Double(min(attempt, 4))), 5_000)
        return UInt64(milliseconds) * 1_000_000
    }

    static func deadline(queryTimeoutSeconds: Int, from start: Date) -> Date? {
        let boundedSeconds = PluginQueryTimeout.boundedSeconds(queryTimeoutSeconds)
        guard boundedSeconds > 0 else { return nil }
        return start.addingTimeInterval(TimeInterval(boundedSeconds + deadlineGraceSeconds))
    }

    static func jobTimeoutMilliseconds(queryTimeoutSeconds: Int) -> String? {
        let boundedSeconds = PluginQueryTimeout.boundedSeconds(queryTimeoutSeconds)
        guard boundedSeconds > 0 else { return nil }
        return String(PluginQueryTimeout.milliseconds(boundedSeconds))
    }

    static func failure(of job: BQJobResponse) -> BigQueryError? {
        guard let errorResult = job.status?.errorResult else { return nil }
        return .jobFailed(message: errorResult.message ?? "", reason: errorResult.reason)
    }
}

private final class BigQueryRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

internal final class BigQueryConnection: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryConnection")
    private static let host = "bigquery.googleapis.com"
    private static let basePath = "/bigquery/v2/"
    private static let pageRowLimit = 10_000
    private static let pageSize = String(pageRowLimit)
    private static let listPageSize = "1000"
    private static let maximumPages = 100
    private static let namedParameterMode = "NAMED"
    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    let projectId: String
    private let location: String?
    private let maximumBytesBilled: String?
    private let tokenProvider: any GoogleAccessTokenProviding
    private let requestTimeout = HttpQueryTimeoutBox()
    private let lock = NSLock()
    private var session: URLSession?
    private var connectDeadline: PluginConnectDeadline?
    private var queryTimeoutSeconds = HttpQueryTimeout.bootstrapSeconds

    init(credentials: BigQueryCredentials, location: String?, maximumBytesBilled: String?) {
        self.projectId = credentials.projectId
        self.tokenProvider = credentials.tokenProvider
        self.location = location
        self.maximumBytesBilled = maximumBytesBilled
    }

    func setQueryTimeout(_ seconds: Int) {
        lock.withLock { queryTimeoutSeconds = seconds }
        requestTimeout.set(serverTimeoutSeconds: seconds)
    }

    func connect(deadline: PluginConnectDeadline? = nil) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(
            HttpQueryTimeout.sessionBootstrapRequestTimeout,
            deadline?.remainingSeconds() ?? 0
        )
        configuration.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let urlSession = URLSession(
            configuration: configuration,
            delegate: BigQueryRedirectRefusingDelegate(),
            delegateQueue: nil
        )
        lock.withLock {
            session = urlSession
            connectDeadline = deadline
        }
        defer { lock.withLock { connectDeadline = nil } }

        do {
            _ = try await executeQuery("SELECT 1")
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        let closing: URLSession? = lock.withLock {
            let current = session
            session = nil
            return current
        }
        closing?.invalidateAndCancel()
    }

    func ping() async throws {
        let url = try endpoint(
            ["projects", projectId, "datasets"],
            query: [URLQueryItem(name: "maxResults", value: "0")]
        )
        _ = try await send(URLRequest(url: url))
    }

    func executeQuery(
        _ sql: String,
        defaultDataset: String? = nil,
        queryParameters: [BigQueryQueryParameter]? = nil
    ) async throws -> BQExecuteResult {
        let run = try await runStatement(sql, defaultDataset: defaultDataset, queryParameters: queryParameters)
        let firstPage = run.firstPage
        var allRows = firstPage.rows ?? []
        var currentPage = firstPage
        var pagesFetched = 1

        while let nextToken = currentPage.pageToken, pagesFetched < Self.maximumPages {
            try Task.checkCancellation()
            let nextPage = try await nextPage(of: run, pageToken: nextToken)
            allRows.append(contentsOf: nextPage.rows ?? [])
            currentPage = nextPage
            pagesFetched += 1
        }

        let statistics = run.statistics
        return BQExecuteResult(
            queryResponse: BQQueryResponse(
                schema: firstPage.schema,
                rows: allRows,
                totalRows: firstPage.totalRows,
                pageToken: currentPage.pageToken,
                jobComplete: firstPage.jobComplete,
                jobReference: firstPage.jobReference,
                numDmlAffectedRows: nil
            ),
            dmlAffectedRows: statistics?.query?.numDmlAffectedRows.flatMap { Int($0) } ?? 0,
            totalBytesProcessed: statistics?.totalBytesProcessed ?? statistics?.query?.totalBytesProcessed,
            totalBytesBilled: statistics?.query?.totalBytesBilled,
            cacheHit: statistics?.query?.cacheHit,
            serverElapsed: statistics?.elapsed
        )
    }

    func runStatement(
        _ sql: String,
        defaultDataset: String? = nil,
        queryParameters: [BigQueryQueryParameter]? = nil
    ) async throws -> BQStatementRun {
        try Task.checkCancellation()
        let timeoutSeconds = lock.withLock {
            connectDeadline.map { max(1, Int($0.remainingSeconds().rounded(.up))) } ?? queryTimeoutSeconds
        }
        let hasParameters = queryParameters?.isEmpty == false
        let started = Date()
        let answer = try await submit(BigQueryStatementRequest(
            query: sql,
            requestId: UUID().uuidString,
            maxResults: Self.pageRowLimit,
            location: location,
            defaultDataset: defaultDataset.flatMap { dataset in
                dataset.isEmpty ? nil : .init(projectId: projectId, datasetId: dataset)
            },
            maximumBytesBilled: maximumBytesBilled,
            parameterMode: hasParameters ? Self.namedParameterMode : nil,
            queryParameters: hasParameters ? queryParameters : nil,
            jobTimeoutMs: BigQueryJobPolling.jobTimeoutMilliseconds(queryTimeoutSeconds: timeoutSeconds)
        ))
        let jobLocation = answer.jobReference?.location

        switch BigQueryStatementProgress(
            jobComplete: answer.jobComplete,
            jobId: answer.jobReference?.jobId,
            pageToken: answer.pageToken
        ) {
        case .unreadable:
            throw BigQueryError.invalidResponse
        case .finished(let jobId):
            return BQStatementRun(firstPage: answer, jobId: jobId, location: jobLocation, statistics: answer.statistics)
        case .running(let jobId):
            do {
                let finished = try await waitForCompletion(
                    jobId: jobId,
                    location: jobLocation,
                    deadline: BigQueryJobPolling.deadline(queryTimeoutSeconds: timeoutSeconds, from: started),
                    timeoutSeconds: timeoutSeconds
                )
                if let failure = BigQueryJobPolling.failure(of: finished) {
                    throw failure
                }
                let firstPage = try await getQueryResults(jobId: jobId, location: jobLocation)
                return BQStatementRun(
                    firstPage: firstPage,
                    jobId: jobId,
                    location: jobLocation,
                    statistics: finished.statistics
                )
            } catch let error as BigQueryError {
                if case .cancelled = error {
                    cancelInBackground(jobId: jobId, location: jobLocation)
                }
                throw error
            }
        }
    }

    func nextPage(of run: BQStatementRun, pageToken: String) async throws -> BQQueryResponse {
        guard let jobId = run.jobId else {
            throw BigQueryError.invalidResponse
        }
        return try await getQueryResults(jobId: jobId, location: run.location, pageToken: pageToken)
    }

    func dryRunQuery(_ sql: String, defaultDataset: String? = nil) async throws -> BQExecuteResult {
        let job = try await dryRun(sql, defaultDataset: defaultDataset, parameterMode: nil)
        let statistics = job.statistics
        return BQExecuteResult(
            queryResponse: BQQueryResponse(
                schema: nil,
                rows: nil,
                totalRows: "0",
                pageToken: nil,
                jobComplete: true,
                jobReference: nil,
                numDmlAffectedRows: nil
            ),
            dmlAffectedRows: 0,
            totalBytesProcessed: statistics?.totalBytesProcessed ?? statistics?.query?.totalBytesProcessed ?? "0",
            totalBytesBilled: statistics?.query?.totalBytesBilled ?? "0",
            cacheHit: statistics?.query?.cacheHit ?? false
        )
    }

    func undeclaredParameters(
        _ sql: String,
        defaultDataset: String? = nil
    ) async throws -> [BigQueryQueryParameter] {
        let job = try await dryRun(sql, defaultDataset: defaultDataset, parameterMode: Self.namedParameterMode)
        return job.statistics?.query?.undeclaredQueryParameters ?? []
    }

    func getQueryResults(
        jobId: String,
        location: String?,
        pageToken: String? = nil
    ) async throws -> BQQueryResponse {
        var query = [URLQueryItem(name: "maxResults", value: Self.pageSize)]
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let location {
            query.append(URLQueryItem(name: "location", value: location))
        }
        let url = try endpoint(["projects", projectId, "queries", jobId], query: query)

        var attempt = 0
        while true {
            let response: BQQueryResponse = try await decode(send(URLRequest(url: url)))
            guard response.jobComplete == false else { return response }
            try await sleep(nanoseconds: BigQueryJobPolling.backoffNanoseconds(attempt: attempt))
            attempt += 1
        }
    }

    func listDatasets() async throws -> [String] {
        var datasets: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: Self.listPageSize)]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let url = try endpoint(["projects", projectId, "datasets"], query: query)
            let page: BQDatasetListResponse = try await decode(send(URLRequest(url: url)))
            datasets.append(contentsOf: page.datasets?.map(\.datasetReference.datasetId) ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return datasets
    }

    func listTables(datasetId: String) async throws -> [BQTableListResponse.BQTableEntry] {
        var tables: [BQTableListResponse.BQTableEntry] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: Self.listPageSize)]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let url = try endpoint(["projects", projectId, "datasets", datasetId, "tables"], query: query)
            let page: BQTableListResponse = try await decode(send(URLRequest(url: url)))
            tables.append(contentsOf: page.tables ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return tables
    }

    func getTable(datasetId: String, tableId: String) async throws -> BQTableResource {
        let url = try endpoint(["projects", projectId, "datasets", datasetId, "tables", tableId])
        return try await decode(send(URLRequest(url: url)))
    }

    func cancelJob(jobId: String, location: String?) async throws {
        let query = location.map { [URLQueryItem(name: "location", value: $0)] } ?? []
        var request = URLRequest(url: try endpoint(["projects", projectId, "jobs", jobId, "cancel"], query: query))
        request.httpMethod = "POST"
        _ = try await send(request)
    }

    // Runs apart from the caller's task: cancelling the request on the wire would lose the job reference its answer
    // carries, and with it the only way to stop a statement the server has started.
    private func submit(
        _ statement: BigQueryStatementRequest<BigQueryQueryParameter>
    ) async throws -> BQQueryResponse {
        var request = URLRequest(url: try endpoint(["projects", projectId, "queries"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(statement)
        let stop = BigQueryStopSignal()
        let submission = Task { [self] () throws -> BQQueryResponse in
            try await decode(send(request, stop: stop))
        }
        do {
            return try await BigQueryStoppableRequest.value(
                of: submission,
                stop: stop,
                grace: BigQueryStatementPolicy.stopGrace
            ) { [self] answer in
                guard let jobId = BigQueryStatementProgress.jobToCancel(
                    jobComplete: answer.jobComplete,
                    jobId: answer.jobReference?.jobId
                ) else { return }
                cancelInBackground(jobId: jobId, location: answer.jobReference?.location)
            }
        } catch is CancellationError {
            throw BigQueryError.cancelled
        } catch BigQueryError.api(let status, let message, let reason)
            where BigQueryStatementPolicy.isStatementRefusal(status: status) {
            throw BigQueryError.jobFailed(message: message, reason: reason)
        }
    }

    private func waitForCompletion(
        jobId: String,
        location: String?,
        deadline: Date?,
        timeoutSeconds: Int
    ) async throws -> BQJobResponse {
        var attempt = 0
        while true {
            if let deadline, Date() >= deadline {
                cancelInBackground(jobId: jobId, location: location)
                throw BigQueryError.jobTimedOut(seconds: timeoutSeconds)
            }
            try await sleep(nanoseconds: BigQueryJobPolling.backoffNanoseconds(attempt: attempt))
            attempt += 1
            let current = try await getJob(jobId: jobId, location: location)
            if current.status?.state == BigQueryJobPolling.doneState {
                return current
            }
        }
    }

    private func dryRun(
        _ sql: String,
        defaultDataset: String?,
        parameterMode: String?
    ) async throws -> BQJobResponse {
        let request = BQJobRequest(
            jobReference: jobReference(),
            configuration: BQJobRequest.BQJobConfiguration(
                query: queryConfig(
                    sql,
                    defaultDataset: defaultDataset,
                    parameterMode: parameterMode,
                    queryParameters: nil
                ),
                dryRun: true,
                jobTimeoutMs: nil
            )
        )
        let job = try await insertJob(request)
        if let failure = BigQueryJobPolling.failure(of: job) {
            throw failure
        }
        return job
    }

    private func insertJob(_ job: BQJobRequest) async throws -> BQJobResponse {
        var request = URLRequest(url: try endpoint(["projects", projectId, "jobs"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(job)
        return try await decode(send(request))
    }

    private func getJob(jobId: String, location: String?) async throws -> BQJobResponse {
        let query = location.map { [URLQueryItem(name: "location", value: $0)] } ?? []
        let url = try endpoint(["projects", projectId, "jobs", jobId], query: query)
        return try await decode(send(URLRequest(url: url)))
    }

    private func jobReference() -> BQJobRequest.BQJobRequestReference? {
        guard let location else { return nil }
        return BQJobRequest.BQJobRequestReference(projectId: projectId, location: location)
    }

    private func queryConfig(
        _ sql: String,
        defaultDataset: String?,
        parameterMode: String?,
        queryParameters: [BigQueryQueryParameter]?
    ) -> BQJobRequest.BQQueryConfig {
        BQJobRequest.BQQueryConfig(
            query: sql,
            useLegacySql: false,
            defaultDataset: defaultDataset.flatMap { dataset in
                dataset.isEmpty ? nil : BQJobRequest.BQDatasetReference(projectId: projectId, datasetId: dataset)
            },
            maximumBytesBilled: maximumBytesBilled,
            parameterMode: parameterMode,
            queryParameters: queryParameters
        )
    }

    private func cancelInBackground(jobId: String, location: String?) {
        Task.detached { [self] in
            do {
                try await cancelJob(jobId: jobId, location: location)
            } catch {
                Self.logger.warning("BigQuery job cancel failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func endpoint(_ segments: [String], query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        let encoded = try segments.map { segment -> String in
            guard let escaped = segment.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
                throw BigQueryError.invalidResponse
            }
            return escaped
        }
        components.percentEncodedPath = Self.basePath + encoded.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw BigQueryError.invalidResponse
        }
        return url
    }

    private func currentSession() throws -> URLSession {
        guard let session = lock.withLock({ session }) else {
            throw BigQueryError.notConnected
        }
        return session
    }

    private func send(_ request: URLRequest, stop: BigQueryStopSignal? = nil) async throws -> Data {
        let answer = try await BigQueryRequestLoop.run(
            isStopped: { stop?.isStopped == true },
            authorize: { try await accessToken() },
            send: { token in try await perform(request, token: token) },
            refreshToken: { await tokenProvider.invalidateCachedToken() },
            backoff: { attempt in
                Self.logger.info("BigQuery rate limited, retry \(attempt, privacy: .public)")
                try await sleep(nanoseconds: BigQueryJobPolling.backoffNanoseconds(attempt: attempt))
            }
        )
        guard let answer else {
            throw BigQueryError.cancelled
        }
        guard (200..<300).contains(answer.status) else {
            throw BQErrorResponse.apiError(status: answer.status, data: answer.data)
        }
        return answer.data
    }

    private func perform(_ request: URLRequest, token: String) async throws -> BigQueryRequestLoop.Answer {
        let session = try currentSession()
        var authorized = request
        authorized.timeoutInterval = lock.withLock { connectDeadline }?.remainingSeconds()
            ?? requestTimeout.requestTimeoutInterval
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: authorized)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BigQueryError.invalidResponse
            }
            return BigQueryRequestLoop.Answer(status: httpResponse.statusCode, data: data)
        } catch let error as BigQueryError {
            throw error
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    private func accessToken() async throws -> String {
        do {
            return try await tokenProvider.accessToken()
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    private func sleep(nanoseconds: UInt64) async throws {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            throw BigQueryError.cancelled
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("BigQuery response did not decode as \(String(describing: T.self), privacy: .public)")
            throw BigQueryError.invalidResponse
        }
    }
}
