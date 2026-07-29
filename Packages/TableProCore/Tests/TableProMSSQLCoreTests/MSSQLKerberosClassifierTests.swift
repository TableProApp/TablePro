import Testing
@testable import TableProMSSQLCore

@Suite("MSSQL Kerberos Classifier")
struct MSSQLKerberosClassifierTests {
    @Test("No credentials cache → noCredential")
    func noCredential() {
        #expect(MSSQLKerberosClassifier.classify("gss_init_sec_context: No credentials cache found") == .noCredential)
    }

    @Test("Preauthentication failed → wrongPassword")
    func wrongPassword() {
        #expect(MSSQLKerberosClassifier.classify("krb5: Preauthentication failed") == .wrongPassword)
    }

    @Test("Client not found in Kerberos database → principalUnknown")
    func principalUnknown() {
        #expect(MSSQLKerberosClassifier.classify("Client not found in Kerberos database") == .principalUnknown)
    }

    @Test("Server not found in Kerberos database → spnNotFound")
    func spnNotFound() {
        #expect(MSSQLKerberosClassifier.classify("Server not found in Kerberos database") == .spnNotFound)
    }

    @Test("Clock skew → clockSkew")
    func clockSkew() {
        #expect(MSSQLKerberosClassifier.classify("Clock skew too great") == .clockSkew)
    }

    @Test("Cannot find KDC → realmNotResolved")
    func realmNotResolved() {
        #expect(MSSQLKerberosClassifier.classify("Cannot find KDC for realm CONTOSO.COM") == .realmNotResolved)
    }

    @Test("Ticket expired → ticketExpired")
    func ticketExpired() {
        #expect(MSSQLKerberosClassifier.classify("Ticket expired") == .ticketExpired)
    }

    @Test("An unrelated error is not classified as Kerberos")
    func unrelatedReturnsNil() {
        #expect(MSSQLKerberosClassifier.classify("certificate verify failed") == nil)
        #expect(MSSQLKerberosClassifier.classify("Login failed for user 'sa'") == nil)
    }
}
