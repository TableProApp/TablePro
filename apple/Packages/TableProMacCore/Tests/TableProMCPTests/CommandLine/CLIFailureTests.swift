import Foundation
@testable import TableProMCP
import Testing

struct CLIFailureTests {
    @Test("Tool error codes map to the documented exit status", arguments: [
        ("denied: This connection is read only for external clients.", CLIExitCode.refused),
        ("user_cancelled: The user cancelled this operation.", .refused),
        ("timeout: The query timed out after 5 seconds.", .timedOut),
        ("invalid_argument: Send one statement at a time.", .usage),
        ("query_failed: relation \"user\" does not exist", .failure),
        ("not_connected: The connection is not open.", .failure),
        ("internal_failure: boom", .failure),
        ("no code here", .failure)
    ])
    func toolErrors(text: String, expected: CLIExitCode) {
        #expect(CLIFailure.fromToolError(text: text).exitCode == expected)
    }

    @Test("The message drops the machine-readable code")
    func toolErrorMessage() {
        #expect(CLIFailure.fromToolError(text: "timeout: took too long").message == "took too long")
    }

    @Test("Protocol error codes map to the documented exit status", arguments: [
        (JsonRpcErrorCode.forbidden, CLIExitCode.refused),
        (JsonRpcErrorCode.serverDisabled, .refused),
        (JsonRpcErrorCode.requestTimeout, .timedOut),
        (JsonRpcErrorCode.invalidParams, .usage),
        (JsonRpcErrorCode.rateLimited, .failure),
        (JsonRpcErrorCode.internalError, .failure)
    ])
    func rpcErrors(code: Int, expected: CLIExitCode) {
        #expect(CLIFailure.fromRpcError(code: code, message: "m").exitCode == expected)
    }
}
