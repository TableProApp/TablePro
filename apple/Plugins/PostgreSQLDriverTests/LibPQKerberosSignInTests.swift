import Foundation
import TableProCoreTypes
import TableProPluginKit
import Testing

struct LibPQKerberosSignInTests {
    @Test("A sign-in other than Kerberos resolves to none", arguments: [
        [:],
        ["awsAuth": "off"],
        ["awsAuth": "profile", KerberosAuthFields.principalFieldId: "alice@CORP.EXAMPLE.COM"]
    ] as [[String: String]])
    func otherSignInsResolveToNone(fields: [String: String]) async throws {
        #expect(try await LibPQKerberosSignIn.resolve(additionalFields: fields, timeoutMilliseconds: 1_000) == nil)
    }

    @Test("Kerberos without a principal and password uses the default credential cache")
    func blankCredentialsUseTheDefaultCache() async throws {
        let fields = ["awsAuth": KerberosAuthFields.method, KerberosAuthFields.principalFieldId: "alice@CORP.EXAMPLE.COM"]

        let signIn = try await LibPQKerberosSignIn.resolve(additionalFields: fields, timeoutMilliseconds: 1_000)

        #expect(signIn == LibPQKerberosSignIn(gssEncryptionMode: "prefer", cachePath: nil))
    }

    @Test("Behind a tunnel the server's own host names the service")
    func tunnelKeepsTheServiceHost() async throws {
        let fields = ["awsAuth": KerberosAuthFields.method, "preTunnelHost": "db.corp.example.com"]

        let signIn = try await LibPQKerberosSignIn.resolve(additionalFields: fields, timeoutMilliseconds: 1_000)

        #expect(signIn?.serviceHost == "db.corp.example.com")
    }

    @Test("A server that wants Kerberos tells a password sign-in where to switch")
    func gssRefusalPointsAtKerberos() throws {
        let raw = "connection to server at \"db\" (10.0.0.5), port 5432 failed: authentication method requirement \"!gss\" failed: server requested GSSAPI authentication"

        let error = try #require(LibPQKerberosSignIn.refusedForAnotherSignIn(raw))

        #expect(error.message.contains("Kerberos (GSSAPI)"))
        #expect(error.detail == raw)
        #expect(LibPQKerberosSignIn.refusedForAnotherSignIn("FATAL:  password authentication failed for user \"app\"") == nil)
    }

    @Test("GSS Encryption keeps libpq's three modes and falls back to prefer")
    func gssEncryptionMode() {
        for mode in ["disable", "prefer", "require"] {
            #expect(LibPQKerberosSignIn.gssEncryptionMode(in: [KerberosAuthFields.gssEncryptionFieldId: mode]) == mode)
        }
        #expect(LibPQKerberosSignIn.gssEncryptionMode(in: [:]) == "prefer")
        #expect(LibPQKerberosSignIn.gssEncryptionMode(in: [KerberosAuthFields.gssEncryptionFieldId: "allow"]) == "prefer")
    }

    @Test("A libpq Kerberos failure reads as what to do about it")
    func failureExplainsItself() {
        let raw = "GSSAPI continuation error: Miscellaneous failure (see text): Server not found in Kerberos database"

        let error = LibPQKerberosSignIn.failure(kind: .spnNotFound, serverMessage: raw)

        #expect(error.message.hasPrefix(String(localized: "The PostgreSQL Kerberos service principal is not registered.")))
        #expect(error.message.hasSuffix("(\(raw))"))
    }
}
