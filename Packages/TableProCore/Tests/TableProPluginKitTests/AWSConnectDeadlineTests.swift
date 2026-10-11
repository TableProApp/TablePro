import Foundation
@testable import TableProPluginKit
import XCTest

private final class AWSDeadlineURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedTimeouts: [TimeInterval] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let callIndex = Self.lock.withLock { () -> Int in
            Self.recordedTimeouts.append(request.timeoutInterval)
            return Self.recordedTimeouts.count
        }
        if callIndex == 1 {
            Thread.sleep(forTimeInterval: 0.1)
        }

        let isSSO = request.url?.host?.contains("portal.sso") == true
        let body: Data
        if isSSO {
            let expiration = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
            body = Data(#"{"roleCredentials":{"accessKeyId":"AK","secretAccessKey":"SK","sessionToken":"ST","expiration":\#(expiration)}}"#.utf8)
        } else {
            body = Data("""
                <AssumeRoleResponse><AssumeRoleResult><Credentials>
                <AccessKeyId>AK</AccessKeyId><SecretAccessKey>SK</SecretAccessKey>
                <SessionToken>ST</SessionToken><Expiration>2099-01-01T00:00:00Z</Expiration>
                </Credentials></AssumeRoleResult></AssumeRoleResponse>
                """.utf8)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isSSO ? "application/json" : "text/xml"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.withLock { recordedTimeouts = [] }
    }

    static func timeouts() -> [TimeInterval] {
        lock.withLock { recordedTimeouts }
    }
}

final class AWSConnectDeadlineTests: XCTestCase {
    func testRequestTakesTheRemainingMonotonicBudget() throws {
        let session = URLSession(configuration: .ephemeral)
        session.sessionDescription = AWSHTTP.connectDeadlineSessionDescriptionPrefix + "125.5"
        defer { session.invalidateAndCancel() }

        let deadline = try XCTUnwrap(AWSHTTP.connectDeadline(for: session))
        XCTAssertEqual(deadline.remainingSeconds(at: 120), 5.5)
        XCTAssertNil(deadline.remainingSeconds(at: 125.5))

        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://sts.amazonaws.com")))
        request.timeoutInterval = 60
        try AWSHTTP.applyConnectDeadline(to: &request, session: session, now: 123)
        XCTAssertEqual(request.timeoutInterval, 2.5)
    }

    func testOrdinarySessionKeepsTheCallersRequestTimeout() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://sts.amazonaws.com")))
        request.timeoutInterval = 17

        try AWSHTTP.applyConnectDeadline(to: &request, session: session, now: 500)

        XCTAssertEqual(request.timeoutInterval, 17)
    }

    func testSSOAndSTSRecomputeOneSessionsRemainingDeadline() async throws {
        AWSDeadlineURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AWSDeadlineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        session.sessionDescription = AWSHTTP.connectDeadlineSessionDescriptionPrefix
            + String(ProcessInfo.processInfo.systemUptime + 30)
        defer { session.invalidateAndCancel() }

        let settings = AWSSSOProfileSettings(
            accountId: "111122223333",
            roleName: "Developer",
            startUrl: "https://example.awsapps.com/start",
            region: "us-east-1",
            ssoSession: "work"
        )
        _ = try await AWSSSO.fetchRoleCredentials(
            accessToken: "TOKEN",
            settings: settings,
            profileName: "base",
            session: session
        )
        _ = try await AWSSTS.assumeRole(
            roleArn: "arn:aws:iam::111122223333:role/Admin",
            roleSessionName: "tablepro-test",
            externalId: nil,
            durationSeconds: nil,
            region: "us-east-1",
            baseCredentials: AWSCredentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "ST"),
            session: session
        )

        let timeouts = AWSDeadlineURLProtocol.timeouts()
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertGreaterThan(timeouts[0], 20)
        XCTAssertLessThanOrEqual(timeouts[0], 30)
        XCTAssertGreaterThan(timeouts[1], 0)
        XCTAssertLessThan(timeouts[1], timeouts[0] - 0.05)
    }

    #if os(macOS)
    func testCredentialProcessStopsAtTheConnectDeadline() async {
        let startedAt = Date()
        let deadline = AWSConnectDeadline(
            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 0.05
        )

        do {
            _ = try await AWSCredentialResolver.executeCredentialProcess(
                ["/bin/sleep", "5"],
                profileName: "deadline-test",
                deadline: deadline
            )
            XCTFail("Expected credential_process to time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Expected URLError.timedOut, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testCredentialProcessRespondsToTaskCancellation() async throws {
        let startedAt = Date()
        let task = Task {
            try await AWSCredentialResolver.executeCredentialProcess(
                ["/bin/sleep", "5"],
                profileName: "cancellation-test",
                deadline: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected credential_process cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testCredentialProcessDrainsStdoutAndStderrTogether() async throws {
        let script = """
        dd if=/dev/zero bs=1024 count=128 2>/dev/null
        dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null
        """
        let deadline = AWSConnectDeadline(
            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 5
        )

        let output = try await AWSCredentialResolver.executeCredentialProcess(
            ["/bin/sh", "-c", script],
            profileName: "pipe-test",
            deadline: deadline
        )

        XCTAssertEqual(output.count, 128 * 1_024)
    }
    #endif
}
