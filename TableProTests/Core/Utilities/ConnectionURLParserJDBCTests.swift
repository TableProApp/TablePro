//
//  ConnectionURLParserJDBCTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionURLParserJDBCTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("jdbc:trino imports as Trino, with the port rule applied")
    func jdbcTrinoImports() throws {
        let parsed = try parse("jdbc:trino://trino.example.com:443/hive")
        #expect(parsed.type == .trino)
        #expect(parsed.host == "trino.example.com")
        #expect(parsed.port == 443)
        #expect(parsed.database == "hive")
        #expect(parsed.sslModeResolution == SSLModeResolution(mode: .verifyIdentity, origin: .impliedByPort))
    }

    @Test("jdbc: in front of a registered scheme is dropped, whatever its case")
    func jdbcPrefixIsDropped() throws {
        #expect(try parse("jdbc:postgresql://localhost:5433/app").type == .postgresql)
        #expect(try parse("JDBC:MySQL://db.example.com:3307/shop").type == .mysql)
        #expect(try parse("jdbc:clickhouse://ch.example.com:8443/default").type == .clickhouse)
        #expect(try parse("jdbc:trino://trino.example.com:8443/hive?SSL=true").sslMode == .verifyIdentity)
    }

    @Test("jdbc:sqlserver and jdbc:oracle:thin keep their own parsing")
    func jdbcSpecialCasesStay() throws {
        #expect(try parse("jdbc:sqlserver://sql.example.com:1433/Sales").type == .mssql)
        let oracle = try parse("jdbc:oracle:thin://db.example.com:1521/ORCL")
        #expect(oracle.type == .oracle)
        #expect(oracle.oracleServiceName == "ORCL")
    }

    @Test("JDBC user and password parameters fill the credentials when the URL carries none")
    func jdbcCredentialParameters() throws {
        let parsed = try parse("jdbc:postgresql://db.example.com:5432/app?user=analyst&password=s%26cr%3Det")
        #expect(parsed.username == "analyst")
        #expect(parsed.password == "s&cr=et")
        let trino = try parse("jdbc:trino://trino.example.com:443/hive?user=etl&SSL=true")
        #expect(trino.username == "etl")
    }

    @Test("Credentials in the URL win over user and password parameters")
    func userInfoWinsOverCredentialParameters() throws {
        let parsed = try parse("postgresql://owner:pw@db.example.com/app?user=other&password=other")
        #expect(parsed.username == "owner")
        #expect(parsed.password == "pw")
    }

    @Test("MongoDB keeps user and password parameters as driver options")
    func mongoKeepsCredentialParametersAsOptions() throws {
        let parsed = try parse("mongodb://db.example.com/app?user=x")
        #expect(parsed.username.isEmpty)
        #expect(parsed.mongoQueryParams["user"] == "x")
    }

    @Test("An unknown JDBC subprotocol keeps its full name in the error")
    func unknownJDBCSubprotocolIsReported() {
        guard case .failure(let error) = ConnectionURLParser.parse("jdbc:h2://h.example.com/db") else {
            Issue.record("Expected jdbc:h2 to be rejected")
            return
        }
        #expect(error == .unsupportedScheme("jdbc:h2"))
    }
}
