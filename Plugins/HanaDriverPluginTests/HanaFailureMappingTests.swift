import Foundation
import TableProPluginKit
import XCTest

final class HanaFailureMappingTests: XCTestCase {
    func testRequestedCancellationBecomesCancellationError() {
        let error = map(HanaBridgeFailure(kind: .cancelled), cancellationRequested: true)
        XCTAssertTrue(error is CancellationError)
    }

    func testUnrequestedCancellationStaysAnError() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .cancelled), cancellationRequested: false))
        XCTAssertEqual(error.kind, .cancelled)
        XCTAssertFalse(error.message.isEmpty)
    }

    func testServerErrorKeepsTheHanaCodeAndText() throws {
        let failure = HanaBridgeFailure(kind: .server, code: 259, position: 14, message: "invalid table name: FOO")
        let error = try hanaError(map(failure))

        XCTAssertEqual(error.kind, .server)
        XCTAssertEqual(error.pluginErrorCode, 259)
        XCTAssertEqual(error.pluginErrorMessage, "invalid table name: FOO")
        XCTAssertEqual(error.errorDescription, "[259] invalid table name: FOO")
    }

    func testServerErrorWithoutTextOrCodeStillReadsWell() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .server)))
        XCTAssertNil(error.pluginErrorCode)
        XCTAssertFalse(error.message.isEmpty)
    }

    func testServerCancelIsNotTreatedAsTheUsersStop() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .server, code: 139, message: "current operation cancelled")))
        XCTAssertEqual(error.kind, .server)
        XCTAssertEqual(error.pluginErrorCode, 139)
    }

    func testTimeoutConnectionLostAndClosedHaveTheirOwnText() throws {
        let timeout = try hanaError(map(HanaBridgeFailure(kind: .timeout)))
        let lost = try hanaError(map(HanaBridgeFailure(kind: .connectionLost, message: "EOF")))
        let closed = try hanaError(map(HanaBridgeFailure(kind: .closed)))

        XCTAssertEqual(timeout.kind, .timeout)
        XCTAssertEqual(lost.kind, .connectionLost)
        XCTAssertEqual(lost.detail, "EOF")
        XCTAssertTrue(lost.message.lowercased().contains("lost connection"))
        XCTAssertEqual(closed.kind, .closed)
        XCTAssertTrue(closed.message.lowercased().contains("connection is closed"))
        XCTAssertEqual(Set([timeout.message, lost.message, closed.message]).count, 3)
    }

    func testTimeoutIsReportedEvenWhenTheUserAlsoCancelled() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .timeout), cancellationRequested: true))
        XCTAssertEqual(error.kind, .timeout)
    }

    func testParameterErrorsNameThePositionValueAndFormat() throws {
        let cases: [(expected: String, fragment: String)] = [
            ("date", "YYYY-MM-DD"),
            ("time", "HH:MM:SS"),
            ("seconddate", "YYYY-MM-DD HH:MM:SS"),
            ("timestamp", "YYYY-MM-DD HH:MM:SS.FFFFFFF"),
            ("boolean", "TRUE or FALSE"),
            ("integer", "whole number"),
            ("decimal", "decimal number"),
            ("double", "number"),
            ("scale", "decimal places"),
            ("hex", "well-known binary"),
            ("unexpected", "could not be converted")
        ]
        for testCase in cases {
            let failure = HanaBridgeFailure(kind: .parameter, message: "bad value", parameter: 3, expected: testCase.expected)
            let error = try hanaError(map(failure))

            XCTAssertEqual(error.kind, .parameter, testCase.expected)
            XCTAssertTrue(error.message.contains("3"), testCase.expected)
            XCTAssertTrue(error.message.contains("bad value"), testCase.expected)
            XCTAssertTrue(error.message.contains(testCase.fragment), testCase.expected)
        }
    }

    func testOutputParameterNamesItsPosition() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .parameter, parameter: 2, expected: "output")))
        XCTAssertEqual(error.kind, .parameter)
        XCTAssertTrue(error.message.contains("2"))
        XCTAssertTrue(error.message.contains("OUT parameter"))
    }

    func testTLSCodesBecomeHandshakeErrors() {
        let untrusted = map(HanaBridgeFailure(kind: .tls, code: 1, message: "x509: unknown authority"))
        let mismatch = map(HanaBridgeFailure(kind: .tls, code: 2, message: "x509: certificate is valid for a"))
        let plaintext = map(HanaBridgeFailure(kind: .tls, code: 3, message: "tls: first record does not look like TLS"))
        let key = map(HanaBridgeFailure(kind: .tls, code: 4, message: "tls: failed to parse private key"))
        let unknown = map(HanaBridgeFailure(kind: .tls, code: 99, message: "?"))

        guard case .untrustedCertificate(let untrustedMessage) = untrusted as? SSLHandshakeError else {
            return XCTFail("expected untrustedCertificate, got \(untrusted)")
        }
        XCTAssertEqual(untrustedMessage, "x509: unknown authority")
        guard case .hostnameMismatch = mismatch as? SSLHandshakeError else {
            return XCTFail("expected hostnameMismatch, got \(mismatch)")
        }
        guard case .serverRequiresPlaintext = plaintext as? SSLHandshakeError else {
            return XCTFail("expected serverRequiresPlaintext, got \(plaintext)")
        }
        guard case .clientKeyInvalid = key as? SSLHandshakeError else {
            return XCTFail("expected clientKeyInvalid, got \(key)")
        }
        guard case .unknown = unknown as? SSLHandshakeError else {
            return XCTFail("expected unknown, got \(unknown)")
        }
    }

    func testConfigurationConnectAndInternalCarryTheBridgeDetail() throws {
        let configuration = try hanaError(map(HanaBridgeFailure(kind: .configuration, message: "missing host")))
        let connect = try hanaError(map(HanaBridgeFailure(kind: .connect, message: "dial tcp: connection refused")))
        let internalFailure = try hanaError(map(HanaBridgeFailure(kind: .internalFailure, message: "panic: boom")))

        XCTAssertEqual(configuration.kind, .configuration)
        XCTAssertEqual(configuration.detail, "missing host")
        XCTAssertEqual(connect.kind, .connect)
        XCTAssertEqual(connect.detail, "dial tcp: connection refused")
        XCTAssertEqual(internalFailure.kind, .internalFailure)
        XCTAssertEqual(internalFailure.detail, "panic: boom")
        XCTAssertNotEqual(connect.message, "dial tcp: connection refused")
    }

    func testConnectTimeoutIsNotReportedAsAQueryTimeout() throws {
        let queryTimeout = try hanaError(map(HanaBridgeFailure(kind: .timeout)))
        let connectTimeout = try hanaError(
            HanaFailureMapping.connectError(for: HanaBridgeFailure(kind: .timeout), cancellationRequested: false)
        )

        XCTAssertEqual(connectTimeout.kind, .connect)
        XCTAssertTrue(connectTimeout.message.contains("30"))
        XCTAssertNotEqual(connectTimeout.message, queryTimeout.message)

        let remaining = try hanaError(HanaFailureMapping.connectError(
            for: HanaBridgeFailure(kind: .timeout),
            cancellationRequested: false,
            timeoutSeconds: 1.25
        ))
        XCTAssertTrue(remaining.message.contains("2"))
    }

    func testConnectMappingLeavesOtherKindsAlone() throws {
        let failure = HanaBridgeFailure(kind: .connect, message: "dial tcp: connection refused")
        let connect = try hanaError(HanaFailureMapping.connectError(for: failure, cancellationRequested: false))
        XCTAssertEqual(connect, try hanaError(map(failure)))
        XCTAssertTrue(
            HanaFailureMapping.connectError(for: HanaBridgeFailure(kind: .cancelled), cancellationRequested: true)
                is CancellationError
        )
    }

    func testEmptyBridgeDetailIsDropped() throws {
        let error = try hanaError(map(HanaBridgeFailure(kind: .connect, message: "  ")))
        XCTAssertNil(error.detail)
    }

    private func map(_ failure: HanaBridgeFailure, cancellationRequested: Bool = false) -> any Error {
        HanaFailureMapping.error(for: failure, cancellationRequested: cancellationRequested)
    }

    private func hanaError(_ error: any Error) throws -> HanaError {
        try XCTUnwrap(error as? HanaError, "expected HanaError, got \(error)")
    }
}
