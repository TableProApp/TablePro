import XCTest
@testable import TableProOracleCore

final class OracleTLSMapperTests: XCTestCase {
    private let missingPath = "/nonexistent/tablepro-oracle-tests/ca.pem"

    func testDisabledModeNeverConsultsTheFilesystem() throws {
        let description = OracleTLSDescription(
            mode: .disabled,
            caCertificatePath: missingPath,
            clientCertificatePath: missingPath,
            clientKeyPath: missingPath
        )
        XCTAssertNoThrow(try OracleTLSMapper.tls(for: description))
    }

    func testRequiredModeWithNoCertificatePathsUsesSystemTrustRoots() {
        XCTAssertNoThrow(try OracleTLSMapper.tls(for: OracleTLSDescription(mode: .required)))
    }

    func testRequiredModeIgnoresCAPathBecauseItDoesNotVerify() {
        let description = OracleTLSDescription(mode: .required, caCertificatePath: missingPath)
        XCTAssertNoThrow(try OracleTLSMapper.tls(for: description))
    }

    func testUnreadableCAPathThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .verifyCA, caCertificatePath: missingPath)
        assertCertificateUnavailable(for: description, field: .certificateAuthority)
    }

    func testUnreadableClientCertificateThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .required, clientCertificatePath: missingPath)
        assertCertificateUnavailable(for: description, field: .clientCertificate)
    }

    func testUnreadableClientKeyThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .required, clientKeyPath: missingPath)
        assertCertificateUnavailable(for: description, field: .clientKey)
    }

    func testEmptyPathsAreTreatedAsAbsent() {
        let description = OracleTLSDescription(
            mode: .verifyIdentity,
            caCertificatePath: "",
            clientCertificatePath: "",
            clientKeyPath: ""
        )
        XCTAssertNil(description.caCertificatePath)
        XCTAssertNil(description.clientCertificatePath)
        XCTAssertNil(description.clientKeyPath)
        XCTAssertNoThrow(try OracleTLSMapper.tls(for: description))
    }

    func testCertificateVerificationPerMode() {
        XCTAssertEqual(OracleTLSMapper.certificateVerification(for: .verifyIdentity), .fullVerification)
        XCTAssertEqual(OracleTLSMapper.certificateVerification(for: .verifyCA), .noHostnameVerification)
        XCTAssertEqual(OracleTLSMapper.certificateVerification(for: .required), .none)
        XCTAssertEqual(OracleTLSMapper.certificateVerification(for: .disabled), .none)
    }

    private func assertCertificateUnavailable(
        for description: OracleTLSDescription,
        field: OracleCertificateField,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try OracleTLSMapper.tls(for: description), file: file, line: line) { error in
            guard case .certificateUnavailable(let thrownField, let path) = error as? OracleCoreError else {
                XCTFail("expected certificateUnavailable, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(thrownField, field, file: file, line: line)
            XCTAssertEqual(path, missingPath, file: file, line: line)
        }
    }
}
