import Foundation
import TableProCoreTypes
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MariaDBKerberosSignInTests {
    private let deadline = MySQLConnectDeadline(timeout: MySQLConnectTimeout(milliseconds: 5_000))

    @Test("A sign-in other than Kerberos resolves to none")
    func otherSignInsResolveToNone() async throws {
        #expect(try await MariaDBKerberosSignIn.resolve(additionalFields: [:], deadline: deadline) == nil)
        #expect(try await MariaDBKerberosSignIn.resolve(additionalFields: ["awsAuth": "sso"], deadline: deadline) == nil)
    }

    @Test("Kerberos without a principal and password uses the default credential cache")
    func blankCredentialsUseTheDefaultCache() async throws {
        let fields = ["awsAuth": KerberosAuthFields.method, KerberosAuthFields.passwordFieldId: "secret"]

        let signIn = try await MariaDBKerberosSignIn.resolve(additionalFields: fields, deadline: deadline)

        #expect(signIn == MariaDBKerberosSignIn(cachePath: nil))
    }

    @Test("A ticket request with no time left fails as a connect timeout without asking the KDC")
    func expiredDeadlineTimesOut() async {
        let expired = MySQLConnectDeadline(
            timeout: MySQLConnectTimeout(milliseconds: 1_000),
            startedAt: .now - .seconds(5)
        )
        let fields = [
            "awsAuth": KerberosAuthFields.method,
            KerberosAuthFields.principalFieldId: "alice@CORP.EXAMPLE.COM",
            KerberosAuthFields.passwordFieldId: "secret"
        ]

        await #expect {
            _ = try await MariaDBKerberosSignIn.resolve(additionalFields: fields, deadline: expired)
        } throws: { error in
            (error as? MariaDBPluginError)?.isConnectionTimeout == true
        }
    }

    @Test("No ticket on macOS reaches Connector/C as a bare GSS failure, read as a missing ticket")
    func bareFailureIsAMissingTicket() {
        let noTicket = "Client GSSAPI error (major 851968, minor 0) : gss_init_sec_context -  Miscellaneous failure (see text). "
        #expect(MariaDBKerberosSignIn.failureKind(for: noTicket) == .noCredential)
        let expired = "Client GSSAPI error (major 851968, minor 2529638944) : gss_init_sec_context - Ticket expired"
        #expect(MariaDBKerberosSignIn.failureKind(for: expired) == .ticketExpired)
        #expect(MariaDBKerberosSignIn.failureKind(for: "Access denied for user 'alice'@'%'") == nil)
    }

    @Test("A Connector/C Kerberos failure keeps its code and says what to do")
    func failureKeepsTheCode() {
        let raw = "Client GSSAPI error (major 851968, minor 0) : gss_init_sec_context - Ticket expired"

        let error = MariaDBKerberosSignIn.failure(kind: .ticketExpired, serverMessage: raw, code: 2_059)

        #expect(error.code == 2_059)
        #expect(error.message.hasPrefix(String(localized: "The Kerberos ticket has expired.")))
        #expect(error.message.hasSuffix("(\(raw))"))
    }
}
