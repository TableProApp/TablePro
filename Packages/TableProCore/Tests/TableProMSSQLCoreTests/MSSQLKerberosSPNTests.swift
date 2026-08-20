import Testing
@testable import TableProMSSQLCore

@Suite("MSSQL Kerberos SPN")
struct MSSQLKerberosSPNTests {
    @Test("Realm-qualified SPN is built and the realm is upper-cased")
    func buildsRealmQualifiedSPN() {
        #expect(
            MSSQLKerberosSPN.build(host: "sql.example.com", port: 1433, realm: "resource.realm.com")
                == "MSSQLSvc/sql.example.com:1433@RESOURCE.REALM.COM"
        )
    }

    @Test("No realm yields no SPN, so FreeTDS keeps its default")
    func nilRealmReturnsNil() {
        #expect(MSSQLKerberosSPN.build(host: "sql.example.com", port: 1433, realm: nil) == nil)
    }

    @Test("Empty or whitespace-only realm yields no SPN")
    func emptyRealmReturnsNil() {
        #expect(MSSQLKerberosSPN.build(host: "sql.example.com", port: 1433, realm: "") == nil)
        #expect(MSSQLKerberosSPN.build(host: "sql.example.com", port: 1433, realm: "   ") == nil)
    }

    @Test("Whitespace is trimmed from host and realm")
    func trimsWhitespace() {
        #expect(
            MSSQLKerberosSPN.build(host: " sql.example.com ", port: 1433, realm: " resource.realm.com ")
                == "MSSQLSvc/sql.example.com:1433@RESOURCE.REALM.COM"
        )
    }

    @Test("A non-default port is included in the SPN")
    func includesNonDefaultPort() {
        #expect(
            MSSQLKerberosSPN.build(host: "sql.example.com", port: 14330, realm: "R.COM")
                == "MSSQLSvc/sql.example.com:14330@R.COM"
        )
    }
}
