import Testing
import TableProPluginKit

@Suite("Oracle channel-fatal error classification")
struct OracleConnectionErrorTests {
    @Test("Decode and connection failures are treated as channel-fatal")
    func channelFatalCodes() {
        #expect(OracleChannelFatalCode.isChannelFatal("connectionError"))
        #expect(OracleChannelFatalCode.isChannelFatal("messageDecodingFailure"))
        #expect(OracleChannelFatalCode.isChannelFatal("unexpectedBackendMessage"))
    }

    @Test("Server-side SQL errors keep the connection alive")
    func nonFatalCodes() {
        #expect(!OracleChannelFatalCode.isChannelFatal("server"))
        #expect(!OracleChannelFatalCode.isChannelFatal("statementCancelled"))
        #expect(!OracleChannelFatalCode.isChannelFatal("malformedStatement"))
    }
}
