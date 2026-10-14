import Foundation
import TableProImport
import Testing

struct ShareableAdditionalFieldsTests {
    @Test func testLeavesOutEveryImportBlockedKeyInAnyCase() {
        let fields = [
            "preConnectScript": "export PGTOKEN=secret-token",
            "usePgpass": "true",
            "PROMPTFORPASSWORD": "true",
            "awsRegion": "us-east-1",
            "sslClientKeyPassphrase": "hunter2",
            "connectionOptions": "-c search_path=app"
        ]

        let shareable = ExportableConnection.shareableAdditionalFields(fields)

        #expect(shareable == ["connectionOptions": "-c search_path=app"])
    }

    @Test func testLeavesOutTheExcludedKeys() {
        let fields = ["mssqlKerberosPassword": "secret", "mssqlAuthMethod": "kerberos"]

        let shareable = ExportableConnection.shareableAdditionalFields(
            fields,
            excluding: ["mssqlKerberosPassword"]
        )

        #expect(shareable == ["mssqlAuthMethod": "kerberos"])
    }

    @Test func testReturnsNilWhenNothingIsLeftToShare() {
        let fields = ["preConnectScript": "echo hi", "usePgpass": "true"]

        #expect(ExportableConnection.shareableAdditionalFields(fields) == nil)
        #expect(ExportableConnection.shareableAdditionalFields([:]) == nil)
    }
}
