//
//  ConnectionURLParserTLSPortTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionURLParserTLSPortTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    private func resolution(_ urlString: String) throws -> SSLModeResolution {
        try parse(urlString).sslModeResolution
    }

    @Test("trino on port 443 with no SSL parameter implies Verify Identity")
    func trinoOn443ImpliesVerifyIdentity() throws {
        let parsed = try parse("trino://analyst@trino.example.com:443/hive")
        #expect(parsed.sslMode == nil)
        #expect(parsed.sslModeResolution == SSLModeResolution(mode: .verifyIdentity, origin: .impliedByPort))
    }

    @Test("An explicit ssl=false keeps port 443 on plain HTTP, as the Trino JDBC driver does")
    func explicitSSLFalseWinsOverThePort() throws {
        for url in [
            "trino://trino.example.com:443/hive?SSL=false",
            "trino://trino.example.com:443/hive?ssl=false",
            "trino://trino.example.com:443/hive?tls=false",
            "trino://trino.example.com:443/hive?SSL=false&SSLVerification=FULL"
        ] {
            #expect(try resolution(url) == SSLModeResolution(mode: .disabled, origin: .chosen), "\(url)")
        }
    }

    @Test("An explicit SSL mode is kept and the port adds nothing")
    func explicitModeIsKept() throws {
        #expect(try resolution("trino://trino.example.com:443/hive?sslmode=require")
            == SSLModeResolution(mode: .required, origin: .chosen))
    }

    @Test("trino on 8443 or its default port implies nothing, since no Trino client infers TLS there")
    func trinoOtherPortsImplyNothing() throws {
        let plain = SSLModeResolution(mode: .disabled, origin: .typeDefault)
        #expect(try resolution("trino://trino.example.com:8443/hive") == plain)
        #expect(try resolution("trino://trino.example.com:8080/hive") == plain)
        #expect(try resolution("trino://trino.example.com/hive") == plain)
    }

    @Test("ClickHouse on 443 or 8443 implies Verify Identity, and on 8123 nothing")
    func clickHouseTLSPorts() throws {
        let implied = SSLModeResolution(mode: .verifyIdentity, origin: .impliedByPort)
        #expect(try resolution("clickhouse://default@ch.example.com:8443/default") == implied)
        #expect(try resolution("clickhouse://default@ch.example.com:443/default") == implied)
        #expect(try resolution("clickhouse://default@ch.example.com:8123/default").mode == .disabled)
    }

    @Test("SSL=true turns on Verify Identity where the driver checks the system trust store, and Required elsewhere")
    func sslTrueFollowsTheDriver() throws {
        #expect(try parse("trino://trino.example.com:8443/hive?SSL=true").sslMode == .verifyIdentity)
        #expect(try parse("clickhouse://ch.example.com:8443/default?ssl=true").sslMode == .verifyIdentity)
        #expect(try parse("postgresql://db.example.com/app?ssl=true").sslMode == .required)
        #expect(try parse("mongodb://db.example.com/app?tls=true").sslMode == .required)
        #expect(try parse("mongodb://a.example.com:27017,b.example.com:27017/app?tls=true").sslMode == .required)
        #expect(try parse("postgresql+ssh://deploy@bastion.example.com/app@db.example.com/app?ssl=true").sslMode == .required)
    }

    @Test("ssl=1 and ssl=require turn TLS on as ssl=true does")
    func sslOnSpellings() throws {
        for url in [
            "postgresql://db.example.com/app?ssl=1",
            "postgresql://db.example.com/app?ssl=require",
            "mysql://db.example.com/app?SSL=Required",
            "mongodb://db.example.com/app?tls=1"
        ] {
            #expect(try parse(url).sslMode == .required, "\(url)")
        }
    }

    @Test("ssl=0 turns TLS off as ssl=false does, even on a port that implies it")
    func sslOffSpelling() throws {
        let parsed = try parse("trino://trino.example.com:443/hive?ssl=0")
        #expect(parsed.disablesTLS)
        #expect(parsed.sslModeResolution == SSLModeResolution(mode: .disabled, origin: .chosen))
    }

    @Test("Trino's SSLVerification picks the check while TLS is on, in either parameter order")
    func sslVerificationPicksTheCheck() throws {
        for (url, expected) in [
            ("trino://h.example.com:8443/hive?SSL=true&SSLVerification=FULL", SSLMode.verifyIdentity),
            ("trino://h.example.com:8443/hive?SSLVerification=CA&SSL=true", .verifyCa),
            ("trino://h.example.com:8443/hive?SSL=true&SSLVerification=none", .required),
            ("trino://h.example.com:443/hive?SSLVerification=CA", .verifyCa)
        ] {
            #expect(try parse(url).sslMode == expected, "\(url)")
        }
        #expect(try parse("trino://h.example.com:8443/hive?SSLVerification=NONE").sslMode == nil)
    }

    @Test("sslmode wins over ssl, tls and SSLVerification, and tlsmode wins over ssl=true in any order")
    func sslModeParameterPrecedence() throws {
        #expect(try parse("trino://h.example.com:8443/hive?SSL=true&SSLVerification=NONE&sslmode=verify-full").sslMode
            == .verifyIdentity)
        #expect(try parse("postgresql://db.example.com/app?ssl=true&tLSMode=4").sslMode == .verifyIdentity)
    }

    @Test("ClickHouse JDBC sslmode strict and none name the certificate check")
    func clickHouseJDBCSSLModes() throws {
        #expect(try parse("clickhouse://ch.example.com:8443/default?ssl=true&sslmode=none").sslMode == .required)
        #expect(try parse("clickhouse://ch.example.com:8443/default?sslmode=strict&ssl=true").sslMode == .verifyIdentity)
    }

    @Test("sslmode accepts underscores and any case")
    func sslModeSpellings() throws {
        #expect(try parse("postgresql://db.example.com/app?sslmode=VERIFY_FULL").sslMode == .verifyIdentity)
        #expect(try parse("postgresql://db.example.com/app?sslmode=verify_ca").sslMode == .verifyCa)
        #expect(try parse("mysql://db.example.com/app?sslmode=VERIFY_IDENTITY").sslMode == .verifyIdentity)
    }

    @Test("TLS turned on with no port picks the driver's TLS port, and a written port is kept")
    func tlsWithoutPortUsesTheTLSPort() throws {
        #expect(try parse("clickhouse://ch.example.com/default?ssl=true").resolvedPort == 8_443)
        #expect(try parse("trino://trino.example.com/hive?SSL=true").resolvedPort == 443)
        #expect(try parse("clickhouse://ch.example.com/default").resolvedPort == 8_123)
        #expect(try parse("clickhouse://ch.example.com/default?ssl=false").resolvedPort == 8_123)
        #expect(try parse("postgresql://db.example.com/app?sslmode=require").resolvedPort == 5_432)
        let written = try parse("clickhouse://ch.example.com:8123/default?ssl=true")
        #expect(written.port == 8_123)
        #expect(written.resolvedPort == 8_123)
    }

    @Test("A deep link to trino on port 443 opens with Verify Identity")
    func transientConnectionUsesTheImpliedMode() throws {
        let connection = TransientConnectionFactory.build(from: try parse("trino://trino.example.com:443/hive"))
        #expect(connection.sslConfig.mode == .verifyIdentity)
        #expect(connection.port == 443)
    }

    @Test("A deep link to trino on port 443 with ssl=false stays on plain HTTP")
    func transientConnectionHonoursSSLFalse() throws {
        let connection = TransientConnectionFactory.build(from: try parse("trino://trino.example.com:443/hive?SSL=false"))
        #expect(connection.sslConfig.mode == .disabled)
    }

    @Test("An etcd URL sets the TLS Mode its driver reads, never the generic SSL Mode it ignores")
    func etcdURLSetsTheDriverTLSMode() throws {
        let cases: [(url: String, tlsMode: String)] = [
            ("etcds://etcd.example.com:2379", "Required"),
            ("etcd://etcd.example.com:2379", "Disabled"),
            ("etcds://etcd.example.com:2379?sslmode=verify-full", "VerifyIdentity"),
            ("etcds://etcd.example.com:2379?sslmode=verify-ca", "VerifyCA"),
            ("etcds://etcd.example.com:2379?sslmode=disable", "Disabled"),
            ("etcd://etcd.example.com:2379?tls=true", "Required"),
            ("etcd://etcd.example.com:2379?sslmode=prefer", "Required"),
            ("etcd://etcd.example.com:2379?tls=false", "Disabled"),
            ("etcd+ssh://me@bastion.example.com/10.0.0.5:2379?sslmode=verify-full", "VerifyIdentity")
        ]
        for (url, tlsMode) in cases {
            let parsed = try parse(url)
            #expect(parsed.additionalFields["etcdTlsMode"] == tlsMode, "\(url)")
            #expect(parsed.sslMode == nil, "\(url)")
            #expect(parsed.disablesTLS == false, "\(url)")
            let connection = TransientConnectionFactory.build(from: parsed)
            #expect(connection.additionalFields["etcdTlsMode"] == tlsMode, "\(url)")
            #expect(connection.sslConfig.mode == .disabled, "\(url)")
        }
    }

    @Test("Only etcd carries its TLS in a plugin field; other engines keep the generic SSL Mode")
    func otherEnginesKeepTheGenericSSLMode() throws {
        let redis = try parse("rediss://cache.example.com")
        #expect(redis.sslMode == .required)
        #expect(redis.additionalFields.isEmpty)
        let postgres = try parse("postgresql+ssh://deploy@bastion.example.com/app@db.example.com/app?sslmode=verify-full")
        #expect(postgres.sslMode == .verifyIdentity)
        #expect(postgres.additionalFields.isEmpty)
    }

    @Test("Importing etcds:// into the form sets TLS Mode to Required, and a plain etcd:// import sets it to Disabled")
    func etcdFormImportSetsTLSMode() throws {
        let secure = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: try parse("etcds://etcd.example.com:2379"))
        secure.start()
        #expect(secure.advanced.additionalFieldValues["etcdTlsMode"] == "Required")
        #expect(secure.ssl.mode == .disabled)

        let plain = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: try parse("etcd://etcd.example.com:2379"))
        plain.start()
        #expect(plain.advanced.additionalFieldValues["etcdTlsMode"] == "Disabled")
    }
}
