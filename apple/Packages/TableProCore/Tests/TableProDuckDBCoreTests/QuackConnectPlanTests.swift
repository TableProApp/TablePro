import Foundation
import TableProDuckDBCore
import Testing

private let pin = "34:FD:9D:AA:82:DD:A4:66:FF:65:9D:56:FA:87:1B:AD:F5:32:4F:4F:A5:BB:6A:09:CD:06:ED:34:9B:B4:AD:58"
private let canonicalPin = "34FD9DAA82DDA466FF659D56FA871BADF5324F4FA5BB6A09CD06ED349BB4AD58"
private let secret = "CREATE OR REPLACE TEMPORARY SECRET tablepro_quack (TYPE quack, TOKEN 'tok')"
private let dropSecret = "DROP TEMPORARY SECRET tablepro_quack"

private func direct(_ mode: QuackSSLMode?, token: String = "tok", ca: String? = nil, fingerprint: String? = nil) throws -> QuackConnectPlan {
    try QuackConnectPlan(QuackConnectRequest(
        host: "192.168.1.3",
        port: "9811",
        alias: "remotedb",
        token: token,
        sslMode: mode?.rawValue,
        caCertificatePath: ca,
        certificateFingerprint: fingerprint
    ))
}

private func tunneled(
    _ mode: QuackSSLMode?,
    server: String = "db.example.com",
    token: String = "tok",
    ca: String? = nil,
    fingerprint: String? = nil
) throws -> QuackConnectPlan {
    try QuackConnectPlan(QuackConnectRequest(
        host: "127.0.0.1",
        port: "50123",
        alias: "remotedb",
        token: token,
        sslMode: mode?.rawValue,
        caCertificatePath: ca,
        certificateFingerprint: fingerprint,
        tunneledServerHost: server
    ))
}

private func statements(_ plan: QuackConnectPlan) -> [String] {
    plan.steps.compactMap {
        guard case .statement(let sql) = $0 else { return nil }
        return sql
    }
}

private func attach(_ plan: QuackConnectPlan) -> String? {
    statements(plan).first { $0.hasPrefix("ATTACH ") }
}

struct QuackConnectPlanTests {
    // MARK: Automatic

    @Test("Automatic on a direct dial names no DISABLE_SSL, so Quack's own host rule decides as it always has")
    func automaticDirect() throws {
        let plan = try direct(.automatic)
        #expect(plan.steps == [
            .loadExtension("quack"),
            .statement(secret),
            .statement("ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" (SECRET tablepro_quack)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
        #expect(plan.mode == .automatic)
        #expect(!plan.isTunneled)
    }

    @Test("A missing, empty or unknown mode is Automatic", arguments: [nil, "", "bogus", "Automatic", "verify-full"])
    func unknownModeIsAutomatic(value: String?) throws {
        let plan = try QuackConnectPlan(QuackConnectRequest(host: "192.168.1.3", token: "tok", sslMode: value))
        #expect(plan.mode == .automatic)
        #expect(attach(plan) == "ATTACH 'quack:192.168.1.3:9494' AS \"remotedb\" (SECRET tablepro_quack)")
    }

    @Test("Automatic through a tunnel to a local server is plain HTTP, Quack's rule for that server's name",
          arguments: ["localhost", "LOCALHOST", "127.0.0.1", "::1", "[::1]"])
    func automaticTunneledLocal(server: String) throws {
        let plan = try tunneled(.automatic, server: server)
        #expect(plan.isTunneled)
        #expect(plan.steps == [
            .loadExtension("quack"),
            .statement(secret),
            .statement("ATTACH 'quack:127.0.0.1:50123' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL true)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
    }

    @Test("Automatic through a tunnel to a non-local server is refused, naming the server",
          arguments: ["db.example.com", "192.168.1.3", "127.0.0.2", "0.0.0.0"])
    func automaticTunneledRemoteIsRefused(server: String) {
        #expect(throws: QuackConnectError.tunneledAutomatic(server: server)) {
            try tunneled(.automatic, server: server)
        }
    }

    // MARK: Disabled

    @Test("Disabled is plain HTTP, direct and tunneled, with no httpfs step")
    func disabled() throws {
        #expect(try direct(.disabled).steps == [
            .loadExtension("quack"),
            .statement(secret),
            .statement("ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL true)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
        let tunnel = try tunneled(.disabled)
        #expect(tunnel.isTunneled)
        #expect(attach(tunnel) == "ATTACH 'quack:127.0.0.1:50123' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL true)")
        #expect(!tunnel.steps.contains(.loadExtension("httpfs")))
    }

    // MARK: Required

    @Test("Required loads httpfs, turns curl's check off before ATTACH and forces HTTPS")
    func requiredDirect() throws {
        #expect(try direct(.required).steps == [
            .loadExtension("quack"),
            .loadExtension("httpfs"),
            .statement("SET GLOBAL enable_curl_server_cert_verification = false"),
            .statement(secret),
            .statement("ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL false)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
    }

    @Test("Required works through a tunnel: nothing checks the name there")
    func requiredTunneled() throws {
        let plan = try tunneled(.required)
        #expect(plan.isTunneled)
        #expect(plan.steps == [
            .loadExtension("quack"),
            .loadExtension("httpfs"),
            .statement("SET GLOBAL enable_curl_server_cert_verification = false"),
            .statement(secret),
            .statement("ATTACH 'quack:127.0.0.1:50123' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL false)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
    }

    // MARK: Verify Identity

    @Test("Verify Identity with no CA forces HTTPS against httpfs's default bundle and sets nothing")
    func verifyIdentityWithoutCA() throws {
        for ca in [nil, "", "   "] {
            #expect(try direct(.verifyIdentity, ca: ca).steps == [
                .loadExtension("quack"),
                .statement(secret),
                .statement("ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL false)"),
                .statement(dropSecret),
                .statement("USE \"remotedb\"")
            ])
        }
    }

    @Test("Verify Identity with a CA loads httpfs and trusts the combined bundle before the secret and ATTACH")
    func verifyIdentityWithCA() throws {
        #expect(try direct(.verifyIdentity, ca: " /Users/me/rootCA.pem ").steps == [
            .loadExtension("quack"),
            .loadExtension("httpfs"),
            .trustCACertificate(path: "/Users/me/rootCA.pem"),
            .statement(secret),
            .statement("ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL false)"),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
    }

    @Test("Verify Identity through a tunnel is refused before dialing, with or without a CA")
    func verifyIdentityTunneledIsRefused() {
        for ca in [nil, "/Users/me/rootCA.pem"] {
            #expect(throws: QuackConnectError.tunneledVerifyIdentity) {
                try tunneled(.verifyIdentity, ca: ca)
            }
            #expect(throws: QuackConnectError.tunneledVerifyIdentity) {
                try tunneled(.verifyIdentity, server: "localhost", ca: ca)
            }
        }
    }

    @Test("The CA path is quoted as a literal in SET GLOBAL ca_cert_file")
    func caCertFileQuoting() {
        #expect(QuackConnectPlan.setCACertFileStatement(bundlePath: "/tmp/it's/ca.pem")
            == "SET GLOBAL ca_cert_file = '/tmp/it''s/ca.pem'")
        #expect(QuackConnectPlan.setCACertFileStatement(bundlePath: "/tmp/x'; SET GLOBAL a = 'b")
            == "SET GLOBAL ca_cert_file = '/tmp/x''; SET GLOBAL a = ''b'")
    }

    // MARK: Verify Fingerprint

    @Test("Verify Fingerprint pins the normalized fingerprint on ATTACH and never loads httpfs")
    func verifyFingerprintDirect() throws {
        #expect(try direct(.verifyFingerprint, fingerprint: "sha256:" + pin.lowercased()).steps == [
            .loadExtension("quack"),
            .statement(secret),
            .statement(
                "ATTACH 'quack:192.168.1.3:9811' AS \"remotedb\" "
                    + "(SECRET tablepro_quack, DISABLE_SSL false, SSL_FINGERPRINT '\(canonicalPin)')"
            ),
            .statement(dropSecret),
            .statement("USE \"remotedb\"")
        ])
    }

    @Test("Verify Fingerprint works through a tunnel to any server")
    func verifyFingerprintTunneled() throws {
        let plan = try tunneled(.verifyFingerprint, fingerprint: pin)
        #expect(plan.isTunneled)
        #expect(attach(plan) == "ATTACH 'quack:127.0.0.1:50123' AS \"remotedb\" "
            + "(SECRET tablepro_quack, DISABLE_SSL false, SSL_FINGERPRINT '\(canonicalPin)')")
        #expect(!plan.steps.contains(.loadExtension("httpfs")))
    }

    @Test("Verify Fingerprint with no fingerprint, or a malformed one, is refused before dialing")
    func verifyFingerprintRefusals() {
        #expect(throws: QuackConnectError.missingFingerprint) { try direct(.verifyFingerprint) }
        #expect(throws: QuackConnectError.missingFingerprint) { try direct(.verifyFingerprint, fingerprint: "  ") }
        #expect(throws: QuackConnectError.invalidFingerprint) { try direct(.verifyFingerprint, fingerprint: "EB:1C:23") }
        #expect(throws: QuackConnectError.invalidFingerprint) { try tunneled(.verifyFingerprint, fingerprint: "zz") }
    }

    @Test("A fingerprint stored under another mode is ignored")
    func fingerprintIgnoredOutsideItsMode() throws {
        let plan = try direct(.required, fingerprint: "not a fingerprint")
        #expect(attach(plan)?.contains("SSL_FINGERPRINT") == false)
    }

    // MARK: Secret

    @Test("The token goes in a named temporary secret that ATTACH names and that is dropped right after it")
    func secretLivesOnlyThroughAttach() throws {
        for mode in QuackSSLMode.allCases {
            let plan = try direct(mode, token: "s3cr3t-token", fingerprint: pin)
            let sql = statements(plan)
            let secretStatement = try #require(sql.first { $0.hasPrefix("CREATE ") })
            #expect(secretStatement == "CREATE OR REPLACE TEMPORARY SECRET tablepro_quack (TYPE quack, TOKEN 's3cr3t-token')")
            let attachStatement = try #require(attach(plan))
            #expect(attachStatement.contains("SECRET tablepro_quack"))
            #expect(!attachStatement.contains("s3cr3t-token"))
            #expect(!attachStatement.contains("TOKEN"))
            let secretIndex = try #require(sql.firstIndex(of: secretStatement))
            let attachIndex = try #require(sql.firstIndex(of: attachStatement))
            let dropIndex = try #require(sql.firstIndex(of: dropSecret))
            #expect(secretIndex < attachIndex)
            #expect(dropIndex == attachIndex + 1)
        }
    }

    @Test("An empty token is refused before dialing, for every mode: Quack has no tokenless connection")
    func emptyTokenIsRefused() {
        for mode in QuackSSLMode.allCases {
            #expect(throws: QuackConnectError.missingToken) { try direct(mode, token: "", fingerprint: pin) }
        }
    }

    // MARK: Tunnel detection

    @Test("A server name with a dial that is not the loopback is a direct dial")
    func serverNameWithoutLoopbackIsDirect() throws {
        let plan = try QuackConnectPlan(QuackConnectRequest(
            host: "10.0.0.5",
            token: "tok",
            sslMode: QuackSSLMode.verifyIdentity.rawValue,
            tunneledServerHost: "db.example.com"
        ))
        #expect(!plan.isTunneled)
        #expect(attach(plan) == "ATTACH 'quack:10.0.0.5:9494' AS \"remotedb\" (SECRET tablepro_quack, DISABLE_SSL false)")
    }

    @Test("A blank server name is a direct dial", arguments: [nil, "", "  "])
    func blankServerNameIsDirect(server: String?) throws {
        let plan = try QuackConnectPlan(QuackConnectRequest(
            host: "localhost",
            token: "tok",
            sslMode: QuackSSLMode.verifyIdentity.rawValue,
            tunneledServerHost: server
        ))
        #expect(!plan.isTunneled)
    }

    // MARK: Host, port and alias

    @Test("A blank host is refused", arguments: ["", "   "])
    func blankHostIsRefused(host: String) {
        #expect(throws: QuackConnectError.missingHost) { try QuackConnectPlan(QuackConnectRequest(host: host, token: "tok")) }
    }

    @Test("An empty port is Quack's default, and one outside 1 to 65535 is refused")
    func ports() throws {
        #expect(try attach(QuackConnectPlan(QuackConnectRequest(host: "h", token: "tok"))) == "ATTACH 'quack:h:9494' AS \"remotedb\" (SECRET tablepro_quack)")
        #expect(try attach(QuackConnectPlan(QuackConnectRequest(host: "h", port: " 9500 ", token: "tok"))) == "ATTACH 'quack:h:9500' AS \"remotedb\" (SECRET tablepro_quack)")
        for port in ["0", "65536", "-1", "abc", "94 94"] {
            #expect(throws: QuackConnectError.invalidPort) { try QuackConnectPlan(QuackConnectRequest(host: "h", port: port, token: "tok")) }
        }
    }

    @Test("A blank alias is remotedb, and an alias is trimmed")
    func aliases() throws {
        #expect(try QuackConnectPlan(QuackConnectRequest(host: "h", alias: "  ", token: "tok")).alias == "remotedb")
        let plan = try QuackConnectPlan(QuackConnectRequest(host: "h", alias: " lake ", token: "tok"))
        #expect(plan.alias == "lake")
        #expect(statements(plan).last == "USE \"lake\"")
    }

    @Test("A bare IPv6 literal is bracketed, as Quack reads its first colon as the port")
    func ipv6() throws {
        #expect(try attach(QuackConnectPlan(QuackConnectRequest(host: "::1", token: "tok"))) == "ATTACH 'quack:[::1]:9494' AS \"remotedb\" (SECRET tablepro_quack)")
        #expect(try attach(QuackConnectPlan(QuackConnectRequest(host: "[::1]", token: "tok"))) == "ATTACH 'quack:[::1]:9494' AS \"remotedb\" (SECRET tablepro_quack)")
        #expect(try attach(QuackConnectPlan(QuackConnectRequest(host: "fe80::1", token: "tok"))) == "ATTACH 'quack:[fe80::1]:9494' AS \"remotedb\" (SECRET tablepro_quack)")
    }

    // MARK: Quoting

    @Test("A hostile host, alias and token stay inside their literals")
    func hostileValuesAreQuoted() throws {
        let plan = try QuackConnectPlan(QuackConnectRequest(
            host: "evil'); DROP TABLE t; --",
            alias: "a\"b; DROP TABLE t",
            token: "t'); DROP TABLE t; --"
        ))
        #expect(statements(plan) == [
            "CREATE OR REPLACE TEMPORARY SECRET tablepro_quack (TYPE quack, TOKEN 't''); DROP TABLE t; --')",
            "ATTACH 'quack:evil''); DROP TABLE t; --:9494' AS \"a\"\"b; DROP TABLE t\" (SECRET tablepro_quack)",
            dropSecret,
            "USE \"a\"\"b; DROP TABLE t\""
        ])
    }

    @Test("A CA path with a quote reaches the bundle step as typed")
    func hostileCAPath() throws {
        let plan = try direct(.verifyIdentity, ca: "/Users/o'brien/ca.pem")
        #expect(plan.steps.contains(.trustCACertificate(path: "/Users/o'brien/ca.pem")))
    }
}
