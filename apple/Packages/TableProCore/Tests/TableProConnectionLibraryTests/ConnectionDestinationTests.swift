import Foundation
import TableProConnectionLibrary
import Testing

struct ConnectionDestinationTests {
    private static func production(
        type: String = "Elasticsearch",
        host: String = "es.prod.internal",
        port: Int = 9_200,
        transport: ConnectionDestination.Transport = .unverified,
        tunnel: ConnectionDestination.Tunnel = .none,
        fields: [String: String] = [:]
    ) -> ConnectionDestination {
        ConnectionDestination(
            type: type, host: host, port: port, transport: transport, tunnel: tunnel, additionalFields: fields
        )
    }

    @Test("A definition that only adds an esHosts list dials somewhere else")
    func hostListChangesTheDigest() {
        let saved = Self.production()
        let crafted = Self.production(fields: ["esHosts": "es.attacker.example:9200"])
        #expect(saved.digest != crafted.digest)
    }

    @Test("Engine, TLS, SSH server, jump host and any plugin field each change the digest")
    func everyRoutingInputChangesTheDigest() {
        let jumpless = ConnectionDestination.Tunnel.ssh(
            server: .init(host: "bastion.prod", port: 22), jumps: []
        )
        let saved = Self.production(transport: .verifyIdentity, tunnel: jumpless)
        let variants = [
            Self.production(type: "OpenSearch", transport: .verifyIdentity, tunnel: jumpless),
            Self.production(port: 9_201, transport: .verifyIdentity, tunnel: jumpless),
            Self.production(transport: .unverified, tunnel: jumpless),
            Self.production(transport: .verifyCA, tunnel: jumpless),
            Self.production(transport: .verifyIdentity, tunnel: .none),
            Self.production(
                transport: .verifyIdentity,
                tunnel: .ssh(server: .init(host: "bastion.attacker.example", port: 22), jumps: [])
            ),
            Self.production(
                transport: .verifyIdentity,
                tunnel: .ssh(
                    server: .init(host: "bastion.prod", port: 22),
                    jumps: [.init(host: "hop.attacker.example", port: 22)]
                )
            ),
            Self.production(transport: .verifyIdentity, tunnel: jumpless, fields: ["esSkipTLSVerify": "true"]),
            Self.production(transport: .verifyIdentity, tunnel: jumpless, fields: ["someFutureField": "x"]),
        ]
        for variant in variants {
            #expect(variant.digest != saved.digest)
        }
    }

    @Test("Host case, padding, empty fields and session settings leave the digest alone")
    func presentationLeavesTheDigestAlone() {
        let saved = Self.production(fields: ["esHosts": "a:9200,b:9200"])
        let same = Self.production(
            host: "  ES.Prod.Internal ",
            fields: [
                "esHosts": " a:9200,b:9200 ",
                "mongoUseSrv": "",
                "connectTimeoutSeconds": "30",
                "queryTimeoutSeconds": "60",
                "preConnectScript": "echo hi",
                "promptForPassword": "true",
                "maskingRules": "[]",
                "mongoParam_proxyPassword": "secret",
            ]
        )
        #expect(saved.digest == same.digest)
    }

    @Test("An SSH port left empty is port 22")
    func emptySSHPortIsTwentyTwo() {
        let implicit = Self.production(tunnel: .ssh(server: .init(host: "bastion", port: nil), jumps: []))
        let explicit = Self.production(tunnel: .ssh(server: .init(host: "bastion", port: 22), jumps: []))
        #expect(implicit.digest == explicit.digest)
    }

    @Test("A field value cannot forge the next entry")
    func valuesCannotForgeEntries() {
        let one = Self.production(fields: ["a": "1", "b": "2"])
        let forged = Self.production(fields: ["a": "11:field.b1:2"])
        #expect(one.digest != forged.digest)
    }

    @Test("The digest is stable across releases")
    func digestIsPinned() {
        let saved = Self.production(
            transport: .verifyCA,
            tunnel: .ssh(server: .init(host: "bastion.prod", port: 22), jumps: [.init(host: "hop", port: 2_222)]),
            fields: ["esHosts": "es1:9200,es2:9200"]
        )
        #expect(saved.digest == ConnectionDestinationTests.pinnedDigest)
    }

    static let pinnedDigest = "v1:add92b9dd77e8f79fd34247da54a5b944914250de770c957e28a232ecf356685"
}
