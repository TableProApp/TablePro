import TableProPluginKit
import Testing

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

@Suite("Oracle connect error classification")
struct OracleConnectErrorClassifierTests {
    @Test("An unclean shutdown is a dropped handshake")
    func uncleanShutdownIsDropped() {
        #expect(OracleConnectErrorClassifier.classify("uncleanShutdown") == .connectionDropped)
    }

    @Test("An unsupported server version is reported as such")
    func serverVersionNotSupported() {
        #expect(OracleConnectErrorClassifier.classify("serverVersionNotSupported") == .versionNotSupported)
    }

    @Test("An unsupported verifier carries its flag through")
    func verifierCarriesFlag() {
        #expect(
            OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x939)")
                == .verifierUnsupported(flag: "unsupportedVerifierType(0x939)")
        )
    }

    @Test("Any other code falls back to a generic connection failure")
    func unknownIsConnectionFailed() {
        #expect(OracleConnectErrorClassifier.classify("connectionError") == .connectionFailed)
        #expect(OracleConnectErrorClassifier.classify("server") == .connectionFailed)
    }
}
