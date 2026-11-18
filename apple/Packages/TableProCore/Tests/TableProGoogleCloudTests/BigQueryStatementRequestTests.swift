//
//  BigQueryStatementRequestTests.swift
//  TableProGoogleCloudTests
//

import Foundation
import TableProGoogleCloud
import Testing

struct BigQueryStatementRequestTests {
    private struct Parameter: Encodable, Sendable {
        let name: String
    }

    private func body(_ request: BigQueryStatementRequest<Parameter>) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(
        location: String? = nil,
        dataset: BigQueryStatementRequest<Parameter>.Dataset? = nil,
        bytes: String? = nil,
        mode: String? = nil,
        parameters: [Parameter]? = nil,
        timeout: String? = nil
    ) -> BigQueryStatementRequest<Parameter> {
        BigQueryStatementRequest(
            query: "SELECT 1",
            requestId: "request-1",
            maxResults: 10_000,
            location: location,
            defaultDataset: dataset,
            maximumBytesBilled: bytes,
            parameterMode: mode,
            queryParameters: parameters,
            jobTimeoutMs: timeout
        )
    }

    @Test("A statement asks to skip the job and answers within the server wait")
    func sendsTheJoblessMode() throws {
        let sent = try body(request())

        #expect(sent["jobCreationMode"] as? String == "JOB_CREATION_OPTIONAL")
        #expect(sent["query"] as? String == "SELECT 1")
        #expect(sent["useLegacySql"] as? Bool == false)
        #expect(sent["requestId"] as? String == "request-1")
        #expect(sent["maxResults"] as? Int == 10_000)
        #expect(sent["timeoutMs"] as? Int == 2_000)
    }

    @Test("What the connection does not set stays out of the body")
    func omitsUnsetFields() throws {
        let sent = try body(request())

        for key in ["location", "defaultDataset", "maximumBytesBilled", "parameterMode", "queryParameters", "jobTimeoutMs"] {
            #expect(sent[key] == nil)
        }
    }

    @Test("Everything jobs.insert carried for a statement is still sent")
    func carriesTheStatementSettings() throws {
        let sent = try body(request(
            location: "EU",
            dataset: .init(projectId: "p", datasetId: "d"),
            bytes: "1000",
            mode: "NAMED",
            parameters: [Parameter(name: "id")],
            timeout: "30000"
        ))

        #expect(sent["location"] as? String == "EU")
        #expect((sent["defaultDataset"] as? [String: String]) == ["projectId": "p", "datasetId": "d"])
        #expect(sent["maximumBytesBilled"] as? String == "1000")
        #expect(sent["parameterMode"] as? String == "NAMED")
        #expect((sent["queryParameters"] as? [[String: String]]) == [["name": "id"]])
        #expect(sent["jobTimeoutMs"] as? String == "30000")
    }

    @Test("A finished statement with no job holds all of its rows")
    func finishedWithoutJob() {
        #expect(BigQueryStatementProgress(jobComplete: true, jobId: nil, pageToken: nil) == .finished(jobId: nil))
    }

    @Test("A finished statement with a job pages through that job")
    func finishedWithJob() {
        #expect(BigQueryStatementProgress(jobComplete: true, jobId: "j", pageToken: "next") == .finished(jobId: "j"))
    }

    @Test("A statement still running is waited on through its job")
    func runningWithJob() {
        #expect(BigQueryStatementProgress(jobComplete: false, jobId: "j", pageToken: nil) == .running(jobId: "j"))
    }

    @Test("An answer that leaves nothing to follow is unreadable", arguments: [
        (false as Bool?, nil as String?, nil as String?),
        (true as Bool?, nil as String?, "next" as String?),
        (nil as Bool?, nil as String?, "next" as String?)
    ])
    func unreadableAnswers(jobComplete: Bool?, jobId: String?, pageToken: String?) {
        #expect(BigQueryStatementProgress(jobComplete: jobComplete, jobId: jobId, pageToken: pageToken) == .unreadable)
    }

    @Test("A refusal of the statement reads as a failed statement", arguments: [400, 403, 404])
    func refusals(status: Int) {
        #expect(BigQueryStatementPolicy.isStatementRefusal(status: status))
    }

    @Test("Auth, rate limit and server errors stay API errors", arguments: [401, 429, 500, 503])
    func notRefusals(status: Int) {
        #expect(!BigQueryStatementPolicy.isStatementRefusal(status: status))
    }
}
