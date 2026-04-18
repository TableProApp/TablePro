//
//  BigQueryConnection.swift
//  BigQueryDriverPlugin
//
//  HTTP client for Google BigQuery REST API v2.
//

import Foundation
import os
import TableProPluginKit

// MARK: - API Response Types

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
    let configuration: BQJobConfiguration

    struct BQJobConfiguration: Codable, Sendable {
        let query: BQQueryConfig?
        let dryRun: Bool?
    }

    struct BQQueryConfig: Codable, Sendable {
        let query: String
        let useLegacySql: Bool
        let maxResults: Int?
        let defaultDataset: BQDatasetReference?
        let timeoutMs: Int?
        let maximumBytesBilled: String?
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
    }

    struct BQQueryStatistics: Codable, Sendable {
        let totalBytesProcessed: String?
        let totalBytesBilled: String?
        let cacheHit: Bool?
        let numDmlAffectedRows: String?
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
        let f: [BQQueryResponse.BQCell]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let str = try? container.decode(String.self) {
            self = .string(str)
            return
        }
        if let record = try? container.decode(BQRecordValue.self) {
            self = .record(record)
            return
        }
        if let array = try? container.decode([BQCellValue].self) {
            self = .array(array)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .null:
            try container.encodeNil()
        case .record(let r):
            try container.encode(r)
        case .array(let a):
            try container.encode(a)
        }
    }
}

internal struct BQJobInfo: Sendable {
    let jobId: String
    let location: String?
}

internal struct BQExecuteResult: Sendable {
    let queryResponse: BQQueryResponse
    let dmlAffectedRows: Int
    let totalBytesProcessed: String?
    let totalBytesBilled: String?
    let cacheHit: Bool?

    init(
        queryResponse: BQQueryResponse,
        dmlAffectedRows: Int,
        totalBytesProcessed: String?,
        totalBytesBilled: String? = nil,
        cacheHit: Bool? = nil
    ) {
        self.queryResponse = queryResponse
        self.dmlAffectedRows = dmlAffectedRows
        self.totalBytesProcessed = totalBytesProcessed
        self.totalBytesBilled = totalBytesBilled
        self.cacheHit = cacheHit
    }
}

private struct BQErrorResponse: Codable {
    let error: BQErrorDetail?

    struct BQErrorDetail: Codable {
        let code: Int?
        let message: String?
        let status: String?
    }
}

// MARK: - BigQuery Connection

internal final class BigQueryConnection: @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _session: URLSession?
    private var _authProvider: BigQueryAuthProvider?
    private var _currentTask: URLSessionDataTask?
    private var _currentJobId: String?
    private var _currentJobLocation: String?
    private var _queryTimeoutSeconds: Int = 300
    private let location: String?
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryConnection")
    private static let baseUrl = "https://bigquery.googleapis.com/bigquery/v2"

    var projectId: String {
        lock.withLock { _authProvider?.projectId ?? "" }
    }

    func setQueryTimeout(_ seconds: Int) {
        lock.withLock { _queryTimeoutSeconds = max(seconds, 30) }
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        let loc = config.additionalFields["bqLocation"]
        self.location = loc?.isEmpty == true ? nil : loc
    }

    func connect() async throws {
        let authProvider = try createAuthProvider()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 300
        let urlSession = URLSession(configuration: sessionConfig)

        lock.withLock {
            _authProvider = authProvider
            _session = urlSession
        }

        // Test connectivity
        do {
            _ = try await executeQuery("SELECT 1")
        } catch {
            lock.withLock {
                _session?.invalidateAndCancel()
                _session = nil
                _authProvider = nil
            }
            throw error
        }
    }

    func disconnect() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
            _currentJobId = nil
            _currentJobLocation = nil
            _session?.invalidateAndCancel()
            _session = nil
            _authProvider = nil
        }
    }

    func ping() async throws {
        let (session, auth) = try getSessionAndAuth()
        let token = try await auth.accessToken()
        var components = URLComponents(string: "\(Self.baseUrl)/projects/\(auth.projectId)/datasets")
        components?.queryItems = [URLQueryItem(name: "maxResults", value: "0")]
        guard let url = components?.url else {
            throw BigQueryError.invalidResponse("Invalid URL for ping")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequestWithRetry(request, session: session)
        try checkHTTPResponse(response, data: data)
    }

    func cancelCurrentRequest() {
        let (task, jobId, jobLocation): (URLSessionDataTask?, String?, String?) = lock.withLock {
            let t = _currentTask
            let j = _currentJobId
            let l = _currentJobLocation
            _currentTask = nil
            return (t, j, l)
        }

        task?.cancel()

        if let jobId {
            Task {
                try? await cancelJob(jobId: jobId, location: jobLocation)
            }
        }
    }

    // MARK: - Query Execution

    func executeQuery(_ sql: String, defaultDataset: String? = nil) async throws -> BQExecuteResult {
        let (session, auth) = try getSessionAndAuth()

        let maxBytes = config.additionalFields["bqMaxBytesBilled"]
        let maxBytesBilled = (maxBytes?.isEmpty == false) ? maxBytes : nil

        let queryConfig = BQJobRequest.BQQueryConfig(
            query: sql,
            useLegacySql: false,
            maxResults: 10000,
            defaultDataset: defaultDataset.map {
                BQJobRequest.BQDatasetReference(projectId: auth.projectId, datasetId: $0)
            },
            timeoutMs: 120_000,
            maximumBytesBilled: maxBytesBilled
        )

        let jobRequest = BQJobRequest(
            configuration: BQJobRequest.BQJobConfiguration(query: queryConfig, dryRun: nil)
        )

        let token = try await auth.accessToken()
        var components = URLComponents(string: "\(Self.baseUrl)/projects/\(auth.projectId)/jobs")
        if let loc = location {
            components?.queryItems = [URLQueryItem(name: "location", value: loc)]
        }
        guard let url = components?.url else {
            throw BigQueryError.invalidResponse("Invalid URL for executeQuery")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(jobRequest)

        let (data, response) = try await performRequestWithRetry(request, session: session)
        try checkHTTPResponse(response, data: data)

        let jobResponse = try JSONDecoder().decode(BQJobResponse.self, from: data)

        guard let jobRef = jobResponse.jobReference,
              let jobId = jobRef.jobId
        else {
            throw BigQueryError.invalidResponse("Missing job reference in response")
        }

        lock.withLock {
            _currentJobId = jobId
            _currentJobLocation = jobRef.location
        }

        // Poll for completion if not done
        let finalJobResponse: BQJobResponse
        if let state = jobResponse.status?.state, state != "DONE" {
            finalJobResponse = try await pollJobCompletion(
                jobId: jobId, location: jobRef.location, auth: auth, session: session
            )
        } else if let errorResult = jobResponse.status?.errorResult {
            let reason = errorResult.reason.map { " [\($0)]" } ?? ""
            throw BigQueryError.jobFailed("\(errorResult.message ?? "Unknown job error")\(reason)")
        } else {
            finalJobResponse = jobResponse
        }

        // Extract DML affected rows from job statistics
        let dmlAffectedRows: Int
        if let numStr = finalJobResponse.statistics?.query?.numDmlAffectedRows {
            dmlAffectedRows = Int(numStr) ?? 0
        } else {
            dmlAffectedRows = 0
        }
        let totalBytesProcessed = finalJobResponse.statistics?.totalBytesProcessed
            ?? finalJobResponse.statistics?.query?.totalBytesProcessed
        let totalBytesBilled = finalJobResponse.statistics?.query?.totalBytesBilled
        let cacheHit = finalJobResponse.statistics?.query?.cacheHit

        // Fetch first page of results
        let firstPage = try await getQueryResults(
            jobId: jobId, location: jobRef.location, auth: auth, session: session
        )
        let schema = firstPage.schema

        // Paginate to accumulate all rows (cap at 100 pages / ~1M rows)
        let maxPages = 100
        var allRows = firstPage.rows ?? []
        var currentPage = firstPage
        var pagesFetched = 1

        while let nextToken = currentPage.pageToken, pagesFetched < maxPages {
            let nextPage = try await getQueryResults(
                jobId: jobId, location: jobRef.location, pageToken: nextToken,
                auth: auth, session: session
            )
            allRows.append(contentsOf: nextPage.rows ?? [])
            currentPage = nextPage
            pagesFetched += 1
        }

        let finalResponse = BQQueryResponse(
            schema: schema,
            rows: allRows,
            totalRows: firstPage.totalRows,
            pageToken: currentPage.pageToken,
            jobComplete: firstPage.jobComplete,
            jobReference: firstPage.jobReference,
            numDmlAffectedRows: nil
        )

        lock.withLock {
            _currentJobId = nil
            _currentJobLocation = nil
        }

        return BQExecuteResult(
            queryResponse: finalResponse,
            dmlAffectedRows: dmlAffectedRows,
            totalBytesProcessed: totalBytesProcessed,
            totalBytesBilled: totalBytesBilled,
            cacheHit: cacheHit
        )
    }

    func getQueryResults(
        jobId: String,
        location: String?,
        pageToken: String? = nil
    ) async throws -> BQQueryResponse {
        let (session, auth) = try getSessionAndAuth()
        return try await getQueryResults(
            jobId: jobId, location: location, pageToken: pageToken,
            auth: auth, session: session
        )
    }

    func clearCurrentJob() {
        lock.withLock {
            _currentJobId = nil
            _currentJobLocation = nil
        }
    }

    func executeJobAndWait(_ sql: String, defaultDataset: String? = nil) async throws -> BQJobInfo {
        let (session, auth) = try getSessionAndAuth()

        let maxBytes = config.additionalFields["bqMaxBytesBilled"]
        let maxBytesBilled = (maxBytes?.isEmpty == false) ? maxBytes : nil

        let queryConfig = BQJobRequest.BQQueryConfig(
            query: sql,
            useLegacySql: false,
            maxResults: 10000,
            defaultDataset: defaultDataset.map {
                BQJobRequest.BQDatasetReference(projectId: auth.projectId, datasetId: $0)
            },
            timeoutMs: 120_000,
            maximumBytesBilled: maxBytesBilled
        )

        let jobRequest = BQJobRequest(
            configuration: BQJobRequest.BQJobConfiguration(query: queryConfig, dryRun: nil)
        )

        let token = try await auth.accessToken()
        var components = URLComponents(string: "\(Self.baseUrl)/projects/\(auth.projectId)/jobs")
        if let loc = location {
            components?.queryItems = [URLQueryItem(name: "location", value: loc)]
        }
        guard let url = components?.url else {
            throw BigQueryError.invalidResponse("Invalid URL for executeJobAndWait")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(jobRequest)

        let (data, response) = try await performRequestWithRetry(request, session: session)
        try checkHTTPResponse(response, data: data)

        let jobResponse = try JSONDecoder().decode(BQJobResponse.self, from: data)

        guard let jobRef = jobResponse.jobReference,
              let jobId = jobRef.jobId
        else {
            throw BigQueryError.invalidResponse("Missing job reference in response")
        }

        lock.withLock {
            _currentJobId = jobId
            _currentJobLocation = jobRef.location
        }

        if let state = jobResponse.status?.state, state != "DONE" {
            let finalJob = try await pollJobCompletion(
                jobId: jobId, location: jobRef.location, auth: auth, session: session
            )
            if let errorResult = finalJob.status?.errorResult {
                let reason = errorResult.reason.map { " [\($0)]" } ?? ""
                throw BigQueryError.jobFailed("\(errorResult.message ?? "Unknown job error")\(reason)")
            }
        } else if let errorResult = jobResponse.status?.errorResult {
            let reason = errorResult.reason.map { " [\($0)]" } ?? ""
            throw BigQueryError.jobFailed("\(errorResult.message ?? "Unknown job error")\(reason)")
        }

        return BQJobInfo(jobId: jobId, location: jobRef.location)
    }

    // MARK: - Dry Run

    func dryRunQuery(_ sql: String, defaultDataset: String? = nil) async throws -> BQExecuteResult {
        let (session, auth) = try getSessionAndAuth()

        let maxBytes = config.additionalFields["bqMaxBytesBilled"]
        let maxBytesBilled = (maxBytes?.isEmpty == false) ? maxBytes : nil

        let queryConfig = BQJobRequest.BQQueryConfig(
            query: sql,
            useLegacySql: false,
            maxResults: nil,
            defaultDataset: defaultDataset.map {
                BQJobRequest.BQDatasetReference(projectId: auth.projectId, datasetId: $0)
            },
            timeoutMs: nil,
            maximumBytesBilled: maxBytesBilled
        )

        let jobRequest = BQJobRequest(
            configuration: BQJobRequest.BQJobConfiguration(query: queryConfig, dryRun: true)
        )

        let token = try await auth.accessToken()
        var components = URLComponents(string: "\(Self.baseUrl)/projects/\(auth.projectId)/jobs")
        if let loc = location {
            components?.queryItems = [URLQueryItem(name: "location", value: loc)]
        }
        guard let url = components?.url else {
            throw BigQueryError.invalidResponse("Invalid URL for dryRunQuery")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(jobRequest)

        let (data, response) = try await performRequestWithRetry(request, session: session)
        try checkHTTPResponse(response, data: data)

        let jobResponse = try JSONDecoder().decode(BQJobResponse.self, from: data)

        let bytesProcessed = jobResponse.statistics?.totalBytesProcessed
            ?? jobResponse.statistics?.query?.totalBytesProcessed ?? "0"
        let bytesBilled = jobResponse.statistics?.query?.totalBytesBilled ?? "0"
        let cacheHit = jobResponse.statistics?.query?.cacheHit ?? false

        let queryResponse = BQQueryResponse(
            schema: nil, rows: nil, totalRows: "0",
            pageToken: nil, jobComplete: true, jobReference: nil, numDmlAffectedRows: nil
        )

        return BQExecuteResult(
            queryResponse: queryResponse,
            dmlAffectedRows: 0,
            totalBytesProcessed: bytesProcessed,
            totalBytesBilled: bytesBilled,
            cacheHit: cacheHit
        )
    }

    // MARK: - Dataset Operations

    func listDatasets() async throws -> [String] {
        let (session, auth) = try getSessionAndAuth()
        let token = try await auth.accessToken()

        var allDatasets: [String] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "\(Self.baseUrl)/projects/\(auth.projectId)/datasets")
            var queryItems = [URLQueryItem(name: "maxResults", value: "1000")]
            if let pt = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pt))
            }
            components?.queryItems = queryItems

            guard let url = components?.url else {
                throw BigQueryError.invalidResponse("Invalid URL for listDatasets")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequestWithRetry(request, session: session)
            try checkHTTPResponse(response, data: data)

            let listResponse = try JSONDecoder().decode(BQDatasetListResponse.self, from: data)
            let names = listResponse.datasets?.map(\.datasetReference.datasetId) ?? []
            allDatasets.append(contentsOf: names)
            pageToken = listResponse.nextPageToken
        } while pageToken != nil

        return allDatasets
    }

    // MARK: - Table Operations

    func listTables(datasetId: String) async throws -> [BQTableListResponse.BQTableEntry] {
        let (session, auth) = try getSessionAndAuth()
        let token = try await auth.accessToken()

        var allTables: [BQTableListResponse.BQTableEntry] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "\(Self.baseUrl)/projects/\(auth.projectId)/datasets/\(datasetId)/tables"
            )
            var queryItems = [URLQueryItem(name: "maxResults", value: "1000")]
            if let pt = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pt))
            }
            components?.queryItems = queryItems

            guard let url = components?.url else {
                throw BigQueryError.invalidResponse("Invalid URL for listTables")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequestWithRetry(request, session: session)
            try checkHTTPResponse(response, data: data)

            let listResponse = try JSONDecoder().decode(BQTableListResponse.self, from: data)
            allTables.append(contentsOf: listResponse.tables ?? [])
            pageToken = listResponse.nextPageToken
        } while pageToken != nil

        return allTables
    }

    func getTable(datasetId: String, tableId: String) async throws -> BQTableResource {
        let (session, auth) = try getSessionAndAuth()
        let token = try await auth.accessToken()

        let urlString = "\(Self.baseUrl)/projects/\(auth.projectId)/datasets/\(datasetId)/tables/\(tableId)"
        guard let url = URL(string: urlString) else {
            throw BigQueryError.invalidResponse("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequestWithRetry(request, session: session)
        try checkHTTPResponse(response, data: data)

        return try JSONDecoder().decode(BQTableResource.self, from: data)
    }

    // MARK: - Job Operations

    func cancelJob(jobId: String, location: String?) async throws {
        let (session, auth) = try getSessionAndAuth()
        let token = try await auth.accessToken()

        var components = URLComponents(
            string: "\(Self.baseUrl)/projects/\(auth.projectId)/jobs/\(jobId)/cancel"
        )
        if let loc = location {
            components?.queryItems = [URLQueryItem(name: "location", value: loc)]
        }

        guard let url = components?.url else {
            throw BigQueryError.invalidResponse("Invalid URL for cancelJob")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await performRequestWithRetry(request, session: session)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            Self.logger.warning("Job cancel returned HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Private Helpers

    private func createAuthProvider() throws -> BigQueryAuthProvider {
        let authMethod = config.additionalFields["bqAuthMethod"] ?? "serviceAccount"
        let overrideProjectId = config.additionalFields["bqProjectId"]

        switch authMethod {
        case "serviceAccount":
            let keyValue = config.additionalFields["bqServiceAccountJson"] ?? config.password
            guard !keyValue.isEmpty else {
                throw BigQueryError.authFailed("Service account key is required")
            }

            let jsonData: Data
            let trimmed = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                guard let data = trimmed.data(using: .utf8) else {
                    throw BigQueryError.authFailed("Failed to encode service account JSON")
                }
                jsonData = data
            } else {
                let path = NSString(string: trimmed).expandingTildeInPath
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw BigQueryError.authFailed("Cannot read service account file: \(trimmed)")
                }
                jsonData = data
            }

            return try ServiceAccountAuthProvider(jsonData: jsonData, overrideProjectId: overrideProjectId)

        case "adc":
            return try ADCAuthProvider(overrideProjectId: overrideProjectId)

        case "oauth":
            let clientId = config.additionalFields["bqOAuthClientId"] ?? ""
            let clientSecret = config.additionalFields["bqOAuthClientSecret"] ?? ""
            let refreshToken = config.additionalFields["bqOAuthRefreshToken"]
            let projectId = config.additionalFields["bqProjectId"] ?? ""

            guard !clientId.isEmpty else {
                throw BigQueryError.authFailed("OAuth Client ID is required")
            }
            guard !clientSecret.isEmpty else {
                throw BigQueryError.authFailed("OAuth Client Secret is required")
            }
            guard !projectId.isEmpty else {
                throw BigQueryError.authFailed("Project ID is required")
            }

            let refreshTokenValue = (refreshToken?.isEmpty == false) ? refreshToken : nil
            return OAuthBrowserAuthProvider(
                clientId: clientId, clientSecret: clientSecret,
                refreshToken: refreshTokenValue, projectId: projectId
            )

        default:
            throw BigQueryError.authFailed("Unknown auth method: \(authMethod)")
        }
    }

    private func getSessionAndAuth() throws -> (URLSession, BigQueryAuthProvider) {
        try lock.withLock {
            guard let session = _session, let auth = _authProvider else {
                throw BigQueryError.notConnected
            }
            return (session, auth)
        }
    }

    private func performRequest(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                self?.lock.withLock { self?._currentTask = nil }
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: BigQueryError.requestCancelled)
                    } else {
                        continuation.resume(
                            throwing: BigQueryError.invalidResponse(error.localizedDescription)
                        )
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: BigQueryError.invalidResponse("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            lock.withLock { _currentTask = task }
            task.resume()
        }
    }

    private func performRequestWithRetry(
        _ request: URLRequest,
        session: URLSession,
        maxRetries: Int = 3
    ) async throws -> (Data, URLResponse) {
        for attempt in 0..<maxRetries {
            let (data, response) = try await performRequest(request, session: session)
            guard let http = response as? HTTPURLResponse, http.statusCode == 429 else {
                return (data, response)
            }
            let delay = UInt64(pow(2.0, Double(attempt) + 1)) * 500_000_000
            Self.logger.info("Rate limited (429), retrying (attempt \(attempt + 1)/\(maxRetries))")
            try await Task.sleep(nanoseconds: delay)
        }
        // Final attempt — no more retries, return whatever the server gives
        return try await performRequest(request, session: session)
    }

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BigQueryError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
            return
        }

        if let errorResponse = try? JSONDecoder().decode(BQErrorResponse.self, from: data),
           let detail = errorResponse.error
        {
            let code = detail.code ?? httpResponse.statusCode
            let message = detail.message ?? "Unknown error"

            if code == 401 {
                throw BigQueryError.authFailed(message)
            }
            if code == 403 {
                throw BigQueryError.apiError(code: 403, message: message)
            }
            throw BigQueryError.apiError(code: code, message: message)
        }

        throw BigQueryError.apiError(
            code: httpResponse.statusCode,
            message: "HTTP \(httpResponse.statusCode) (response length: \(data.count))"
        )
    }

    private func getQueryResults(
        jobId: String,
        location: String?,
        pageToken: String? = nil,
        auth: BigQueryAuthProvider,
        session: URLSession,
        maxAttempts: Int? = nil
    ) async throws -> BQQueryResponse {
        let effectiveMaxAttempts = maxAttempts ?? lock.withLock { _queryTimeoutSeconds } * 2
        var remainingAttempts = effectiveMaxAttempts

        while true {
            let token = try await auth.accessToken()

            var components = URLComponents(
                string: "\(Self.baseUrl)/projects/\(auth.projectId)/queries/\(jobId)"
            )
            var queryItems = [URLQueryItem(name: "maxResults", value: "10000")]
            if let pt = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pt))
            }
            if let loc = location {
                queryItems.append(URLQueryItem(name: "location", value: loc))
            }
            components?.queryItems = queryItems

            guard let url = components?.url else {
                throw BigQueryError.invalidResponse("Invalid URL for getQueryResults")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequestWithRetry(request, session: session)
            try checkHTTPResponse(response, data: data)

            let queryResponse = try JSONDecoder().decode(BQQueryResponse.self, from: data)

            if queryResponse.jobComplete == false {
                remainingAttempts -= 1
                if remainingAttempts <= 0 {
                    throw BigQueryError.timeout("Query results not ready after \(effectiveMaxAttempts) attempts")
                }
                let attempt = effectiveMaxAttempts - remainingAttempts
                let backoffNs = UInt64(min(500 * pow(2.0, Double(min(attempt, 4))), 5000)) * 1_000_000
                try await Task.sleep(nanoseconds: backoffNs)
                continue
            }

            return queryResponse
        }
    }

    @discardableResult
    private func pollJobCompletion(
        jobId: String,
        location: String?,
        auth: BigQueryAuthProvider,
        session: URLSession
    ) async throws -> BQJobResponse {
        let maxAttempts = lock.withLock { _queryTimeoutSeconds } * 2 // 500ms per attempt
        var attempts = 0

        while attempts < maxAttempts {
            let backoffNs = UInt64(min(500 * pow(2.0, Double(min(attempts, 4))), 5000)) * 1_000_000
            try await Task.sleep(nanoseconds: backoffNs)
            attempts += 1

            let token = try await auth.accessToken()

            var components = URLComponents(
                string: "\(Self.baseUrl)/projects/\(auth.projectId)/jobs/\(jobId)"
            )
            if let loc = location {
                components?.queryItems = [URLQueryItem(name: "location", value: loc)]
            }

            guard let url = components?.url else {
                throw BigQueryError.invalidResponse("Invalid URL for pollJobCompletion")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequestWithRetry(request, session: session)
            try checkHTTPResponse(response, data: data)

            let jobResponse = try JSONDecoder().decode(BQJobResponse.self, from: data)

            guard let state = jobResponse.status?.state else {
                throw BigQueryError.invalidResponse("Missing job state")
            }

            if state == "DONE" {
                if let errorResult = jobResponse.status?.errorResult {
                    let reason = errorResult.reason.map { " [\($0)]" } ?? ""
                    throw BigQueryError.jobFailed("\(errorResult.message ?? "Unknown job error")\(reason)")
                }
                return jobResponse
            }
        }

        // Try to cancel the timed-out job
        let timeoutSeconds = lock.withLock { _queryTimeoutSeconds }
        try? await cancelJob(jobId: jobId, location: location)
        throw BigQueryError.timeout("Job did not complete within \(timeoutSeconds) seconds")
    }
}
