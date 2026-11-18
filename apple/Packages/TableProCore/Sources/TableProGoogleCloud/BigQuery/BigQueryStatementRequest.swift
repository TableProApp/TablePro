//
//  BigQueryStatementRequest.swift
//  TableProGoogleCloud
//

import Foundation

public enum BigQueryStatementPolicy {
    public static let jobCreationMode = "JOB_CREATION_OPTIONAL"

    // How long the server holds the request before answering that the statement still runs. Stop waits for this
    // answer, because it carries the job reference the cancel needs.
    public static let serverWaitMilliseconds = 2_000

    // jobs.query reports a statement the server refuses as an HTTP error, where jobs.insert reported it on the job.
    public static func isStatementRefusal(status: Int) -> Bool {
        status == 400 || status == 403 || status == 404
    }
}

// The body of `jobs.query`. `requestId` keeps a retried request from running a write twice.
public struct BigQueryStatementRequest<Parameter: Encodable & Sendable>: Encodable, Sendable {
    public struct Dataset: Encodable, Sendable {
        public let projectId: String
        public let datasetId: String

        public init(projectId: String, datasetId: String) {
            self.projectId = projectId
            self.datasetId = datasetId
        }
    }

    public let query: String
    public let useLegacySql: Bool
    public let jobCreationMode: String
    public let requestId: String
    public let maxResults: Int
    public let timeoutMs: Int
    public let location: String?
    public let defaultDataset: Dataset?
    public let maximumBytesBilled: String?
    public let parameterMode: String?
    public let queryParameters: [Parameter]?
    public let jobTimeoutMs: String?

    public init(
        query: String,
        requestId: String,
        maxResults: Int,
        location: String?,
        defaultDataset: Dataset?,
        maximumBytesBilled: String?,
        parameterMode: String?,
        queryParameters: [Parameter]?,
        jobTimeoutMs: String?
    ) {
        self.query = query
        self.useLegacySql = false
        self.jobCreationMode = BigQueryStatementPolicy.jobCreationMode
        self.requestId = requestId
        self.maxResults = maxResults
        self.timeoutMs = BigQueryStatementPolicy.serverWaitMilliseconds
        self.location = location
        self.defaultDataset = defaultDataset
        self.maximumBytesBilled = maximumBytesBilled
        self.parameterMode = parameterMode
        self.queryParameters = queryParameters
        self.jobTimeoutMs = jobTimeoutMs
    }
}

// What a `jobs.query` answer leaves to do. A statement that finished without a job has no way to page, so a page
// token with no job cannot be followed.
public enum BigQueryStatementProgress: Equatable, Sendable {
    case finished(jobId: String?)
    case running(jobId: String)
    case unreadable

    public init(jobComplete: Bool?, jobId: String?, pageToken: String?) {
        if jobComplete == false {
            self = jobId.map { .running(jobId: $0) } ?? .unreadable
        } else if jobId == nil, pageToken != nil {
            self = .unreadable
        } else {
            self = .finished(jobId: jobId)
        }
    }
}
