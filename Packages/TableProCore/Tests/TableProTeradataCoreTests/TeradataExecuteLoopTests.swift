import XCTest
@testable import TableProTeradataCore

final class TeradataExecuteLoopTests: XCTestCase {
    func testRecordOnlyBatchIsNotComplete() {
        let batch = [Parcel(.record, body: [0x00]), Parcel(.record, body: [0x00])]
        XCTAssertFalse(TeradataConnection.responseIsComplete(batch))
    }

    func testEndRequestTerminatesButEndStatementDoesNot() {
        XCTAssertTrue(TeradataConnection.responseIsComplete([Parcel(.endRequest)]))
        XCTAssertFalse(TeradataConnection.responseIsComplete([Parcel(.record), Parcel(.endStatement)]))
    }

    func testServerFailuresTerminateInsteadOfLooping() {
        XCTAssertTrue(TeradataConnection.responseIsComplete([Parcel(.failure)]))
        XCTAssertTrue(TeradataConnection.responseIsComplete([Parcel(.error)]))
        XCTAssertTrue(TeradataConnection.responseIsComplete([Parcel(.statementError)]))
    }

    func testServerErrorHasReadableLocalizedDescription() {
        let error = TeradataWireError.server(code: 21_608, message: "user does not have SELECT access")
        XCTAssertEqual(error.errorDescription, "user does not have SELECT access (21608)")
        XCTAssertEqual((error as Error).localizedDescription, "user does not have SELECT access (21608)")
    }

    func testFailureParcelSurfacesServerErrorCodeAndMessage() throws {
        let message = Array("no SELECT access".utf8)
        let body: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x54, 0x68, 0x00, UInt8(message.count)] + message
        let parcels = [Parcel(.failure, body: body)]
        XCTAssertThrowsError(try TeradataResultParser.parse(parcels)) { error in
            guard case TeradataWireError.server(let code, let text) = error else {
                return XCTFail("expected server error, got \(error)")
            }
            XCTAssertEqual(code, 21_608)
            XCTAssertEqual(text, "no SELECT access")
        }
    }
}
