import TableProCoreTypes
import Testing

@Suite("Kerberos Failure Classifier")
struct KerberosFailureClassifierTests {
    @Test("No credentials cache → noCredential")
    func noCredential() {
        #expect(KerberosFailureClassifier.classify("gss_init_sec_context: No credentials cache found") == .noCredential)
    }

    @Test("The macOS GSS default cache without a ticket → noCredential")
    func macOSDefaultCacheWithoutTicket() {
        let libpq = "GSSAPI continuation error: Miscellaneous failure (see text): no credential for A1DE3100-79BC-4062-903F-D5E5B8E23DF9"
        #expect(KerberosFailureClassifier.classify(libpq) == .noCredential)
    }

    @Test("libpq on macOS without a ticket → noCredential")
    func macOSLibPQWithoutTicket() {
        let message = "GSSAPI continuation error:  The operation or option is not available: Credential for asked mech-type mech not found in the credential handle"
        #expect(KerberosFailureClassifier.classify(message) == .noCredential)
    }

    @Test("The macOS GSS framework's KDC e-text → principalUnknown and spnNotFound")
    func macOSKDCErrorText() {
        let client = "The operation couldn’t be completed. (org.h5l.GSS error 851968 - Error from KDC: CLIENT_NOT_FOUND)"
        #expect(KerberosFailureClassifier.classify(client) == .principalUnknown)
        let server = "GSSAPI continuation error:  Miscellaneous failure (see text): Error from KDC: LOOKING_UP_SERVER"
            + " while looking up 'postgres/127.0.0.1@TEST.TABLEPRO' (cached result, timeout in 1200 sec)"
        #expect(KerberosFailureClassifier.classify(server) == .spnNotFound)
    }

    @Test("The macOS GSS framework's wrong password → wrongPassword")
    func macOSWrongPassword() {
        let message = "The operation couldn’t be completed. (org.h5l.GSS error 851968 - Decrypt integrity check failed"
            + " for checksum type hmac-sha1-96-aes256, key type aes256-cts-hmac-sha1-96)"
        #expect(KerberosFailureClassifier.classify(message) == .wrongPassword)
    }

    @Test("MIT's missing ticket → noCredential")
    func mitMissingTicket() {
        let message = "Client GSSAPI error (major 851968, minor 2529639053) : gss_init_sec_context - No Kerberos credentials available (default cache: FILE:/tmp/krb5cc_501)"
        #expect(KerberosFailureClassifier.classify(message) == .noCredential)
    }

    @Test("Preauthentication failed → wrongPassword")
    func wrongPassword() {
        #expect(KerberosFailureClassifier.classify("krb5: Preauthentication failed") == .wrongPassword)
    }

    @Test("Client not found in Kerberos database → principalUnknown")
    func principalUnknown() {
        #expect(KerberosFailureClassifier.classify("Client not found in Kerberos database") == .principalUnknown)
    }

    @Test("Server not found in Kerberos database → spnNotFound")
    func spnNotFound() {
        #expect(KerberosFailureClassifier.classify("Server not found in Kerberos database") == .spnNotFound)
    }

    @Test("Clock skew → clockSkew")
    func clockSkew() {
        #expect(KerberosFailureClassifier.classify("Clock skew too great") == .clockSkew)
    }

    @Test("Cannot find KDC → realmNotResolved")
    func realmNotResolved() {
        #expect(KerberosFailureClassifier.classify("Cannot find KDC for realm CONTOSO.COM") == .realmNotResolved)
    }

    @Test("Ticket expired → ticketExpired")
    func ticketExpired() {
        #expect(KerberosFailureClassifier.classify("GSSAPI continuation error: Ticket expired") == .ticketExpired)
    }

    @Test("An unrelated error is not classified as Kerberos")
    func unrelatedReturnsNil() {
        #expect(KerberosFailureClassifier.classify("certificate verify failed") == nil)
        #expect(KerberosFailureClassifier.classify("Login failed for user 'sa'") == nil)
        #expect(KerberosFailureClassifier.classify("FATAL:  password authentication failed for user \"app\"") == nil)
    }
}
