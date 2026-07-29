import XCTest
@testable import TableProTeradataCore

final class TeradataTLSTests: XCTestCase {
    func testDisabledOptionsDoNotEnableTLS() {
        XCTAssertFalse(TeradataTLSOptions.disabled.enabled)
        XCTAssertFalse(TeradataTLSOptions.disabled.verifiesCertificate)
    }

    func testClientAttributesEmbedSSLMode() {
        let parcel = TeradataMessages.clientAttributesParcel(
            username: "u", session: 1, charset: 0xBF, serverIP: "10.0.0.1",
            logMech: "TD2", transactionMode: "ANSI", sslMode: "REQUIRE", database: "db")
        let body = String(decoding: parcel.body, as: UTF8.self)
        XCTAssertTrue(body.contains("SSLM=REQUIRE"), "attributes must carry the negotiated SSL mode")
        XCTAssertTrue(body.contains("LM=TD2"))
        XCTAssertTrue(body.contains("TM=ANSI"))
    }

    func testPlaintextConnectIgnoresTLSFallbackFlag() {
        let config = TeradataConnectionConfig(
            host: "127.0.0.1", port: 9, username: "u", password: "p",
            tls: TeradataTLSOptions(enabled: false, allowPlaintextFallback: true),
            connectTimeoutSeconds: 1)
        XCTAssertThrowsError(try TeradataConnection(config: config).connect()) { error in
            guard case TeradataWireError.connectionFailed = error else {
                if case TeradataWireError.truncated = error { return }
                return XCTFail("expected a transport error, got \(error)")
            }
        }
    }
}
