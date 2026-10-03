import TableProImport
import XCTest

final class ShareableAdditionalFieldsTests: XCTestCase {
    func testLeavesOutEveryImportBlockedKeyInAnyCase() {
        let fields = [
            "preConnectScript": "export PGTOKEN=secret-token",
            "usePgpass": "true",
            "PROMPTFORPASSWORD": "true",
            "awsRegion": "us-east-1",
            "sslClientKeyPassphrase": "hunter2",
            "connectionOptions": "-c search_path=app"
        ]

        let shareable = ExportableConnection.shareableAdditionalFields(fields)

        XCTAssertEqual(shareable, ["connectionOptions": "-c search_path=app"])
    }

    func testLeavesOutTheExcludedKeys() {
        let fields = ["mssqlKerberosPassword": "secret", "mssqlAuthMethod": "kerberos"]

        let shareable = ExportableConnection.shareableAdditionalFields(
            fields,
            excluding: ["mssqlKerberosPassword"]
        )

        XCTAssertEqual(shareable, ["mssqlAuthMethod": "kerberos"])
    }

    func testReturnsNilWhenNothingIsLeftToShare() {
        let fields = ["preConnectScript": "echo hi", "usePgpass": "true"]

        XCTAssertNil(ExportableConnection.shareableAdditionalFields(fields))
        XCTAssertNil(ExportableConnection.shareableAdditionalFields([:]))
    }
}
