import Foundation

public enum BigQueryStatementPolicy {
    public static let jobCreationMode = "JOB_CREATION_OPTIONAL"

    // A stopped statement's job reference arrives within this wait, so its cancel can follow.
    public static let serverWaitMilliseconds = 2_000

    public static let stopGrace: Duration = .seconds(1)

    public static let stoppedRequestLimit: Duration = .seconds(10)

    // The server caps an answer at 10 MB.
    public static let answerByteLimit = 32 * 1_024 * 1_024

    // jobs.query answers a statement the server refuses with these, where jobs.insert reported them on the job.
    public static func isStatementRefusal(status: Int) -> Bool {
        status == 400 || status == 403 || status == 404 || status == 409
    }
}

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
    // A retry with the same id returns the first request's statement instead of running it again.
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

public enum BigQueryStatementProgress: Equatable, Sendable {
    case finished(jobId: String?)
    case running(jobId: String)
    case unreadable

    // A statement that finished without a job cannot page, so a page token with no job cannot be followed.
    public init(jobComplete: Bool?, jobId: String?, pageToken: String?) {
        if jobComplete == false {
            self = jobId.map { .running(jobId: $0) } ?? .unreadable
        } else if jobId == nil, pageToken != nil {
            self = .unreadable
        } else {
            self = .finished(jobId: jobId)
        }
    }

    public static func jobToCancel(jobComplete: Bool?, jobId: String?) -> String? {
        guard case .running(let jobId) = BigQueryStatementProgress(jobComplete: jobComplete, jobId: jobId, pageToken: nil)
        else { return nil }
        return jobId
    }
}
