import TableProMySQLCore
import Testing

struct MySQLPlaintextPasswordTests {
    private func methods(withoutTLS: Bool, kerberos: Bool) -> [String]? {
        MySQLPlaintextPassword.allowedMethods(withoutTLS: withoutTLS, signsInWithKerberos: kerberos)?
            .split(separator: ",").map(String.init)
    }

    @Test("A Kerberos sign-in keeps today's rule: any method over TLS, none that types the password without it")
    func kerberosKeepsTheTLSRule() {
        #expect(methods(withoutTLS: false, kerberos: true) == nil)
        #expect(methods(withoutTLS: true, kerberos: true)?.contains("auth_gssapi_client") == true)
        #expect(methods(withoutTLS: true, kerberos: true)?.contains("mysql_clear_password") == false)
    }

    @Test("Any other sign-in never answers with a Kerberos ticket", arguments: [false, true])
    func otherSignInsRefuseGSSAPI(withoutTLS: Bool) throws {
        let allowed = try #require(methods(withoutTLS: withoutTLS, kerberos: false))

        #expect(!allowed.contains("auth_gssapi_client"))
        #expect(allowed.contains("caching_sha2_password"))
        #expect(allowed.contains("mysql_native_password"))
        #expect(allowed.contains("mysql_clear_password") == !withoutTLS)
        #expect(allowed.contains("dialog") == !withoutTLS)
    }

    @Test("A refused GSSAPI plugin reads as a Kerberos account, any other refusal as the plaintext one")
    func refusalNamesKerberos() {
        let gssapi = "Authentication plugin 'auth_gssapi_client' couldn't be found in restricted_auth plugin list."
        let cleartext = "Authentication plugin 'mysql_clear_password' couldn't be found in restricted_auth plugin list."

        #expect(MySQLPlaintextPassword.isKerberosRefusal(code: 5_010, message: gssapi))
        #expect(!MySQLPlaintextPassword.isKerberosRefusal(code: 5_010, message: cleartext))
        #expect(!MySQLPlaintextPassword.isKerberosRefusal(code: 1_045, message: gssapi))
    }
}
