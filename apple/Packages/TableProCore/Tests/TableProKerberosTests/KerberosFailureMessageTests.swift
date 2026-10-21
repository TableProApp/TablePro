import TableProCoreTypes
import TableProKerberos
import Testing

struct KerberosFailureMessageTests {
    private let spn = (summary: "The service is not registered.", suggestion: "Register postgres/host.")

    @Test("The engine's own text explains an unregistered service principal")
    func spnNotFoundUsesTheEngineText() {
        let text = KerberosFailureMessage.describe(
            kind: .spnNotFound,
            serverMessage: "Server not found in Kerberos database",
            spnNotFound: spn
        )
        #expect(text == "The service is not registered. Register postgres/host. (Server not found in Kerberos database)")
    }

    @Test("Every kind keeps the driver's text at the end")
    func everyKindEndsWithTheServerMessage() {
        let kinds: [KerberosFailureKind] = [
            .noCredential, .principalUnknown, .wrongPassword, .spnNotFound,
            .clockSkew, .realmNotResolved, .ticketExpired
        ]
        for kind in kinds {
            let text = KerberosFailureMessage.describe(kind: kind, serverMessage: "raw", spnNotFound: spn)
            #expect(text.hasSuffix(" (raw)"))
        }
    }

    @Test("A missing ticket points at kinit")
    func noCredentialPointsAtKinit() {
        let text = KerberosFailureMessage.describe(kind: .noCredential, serverMessage: "raw", spnNotFound: spn)
        #expect(text.contains("kinit"))
    }
}
