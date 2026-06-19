import Foundation
import Testing

@testable import TablePro

@Suite("Oracle channel-fatal error classification")
struct OracleConnectionErrorTests {
    @Test("Decode and connection failures are treated as channel-fatal")
    func channelFatalCodes() {
        #expect(OracleConnectionWrapper.isChannelFatalCode("connectionError"))
        #expect(OracleConnectionWrapper.isChannelFatalCode("messageDecodingFailure"))
        #expect(OracleConnectionWrapper.isChannelFatalCode("unexpectedBackendMessage"))
    }

    @Test("Server-side SQL errors keep the connection alive")
    func nonFatalCodes() {
        #expect(!OracleConnectionWrapper.isChannelFatalCode("server"))
        #expect(!OracleConnectionWrapper.isChannelFatalCode("statementCancelled"))
        #expect(!OracleConnectionWrapper.isChannelFatalCode("malformedStatement"))
    }
}
