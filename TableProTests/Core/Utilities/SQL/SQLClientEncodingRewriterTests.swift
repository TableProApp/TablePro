//
//  SQLClientEncodingRewriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLClientEncodingRewriterTests {
    private func mysql(_ statement: String) -> String? {
        SQLClientEncodingRewriter.rewritten(statement, family: .mysql, grammar: TestGrammar.mysql)
    }

    private func postgres(_ statement: String) -> String? {
        SQLClientEncodingRewriter.rewritten(statement, family: .postgres, grammar: TestGrammar.postgres)
    }

    private static let keepsSession = "character_set_client = @@session.character_set_client"

    @Test("A mysqldump character set statement keeps the session's own character set instead")
    func mysqldumpSetNames() {
        #expect(mysql("/*!40101 SET NAMES cp932 */") == "/*!40101 SET \(Self.keepsSession) */")
        #expect(mysql("SET NAMES 'sjis'") == "SET \(Self.keepsSession)")
        #expect(mysql("SET NAMES ujis COLLATE ujis_japanese_ci") == "SET \(Self.keepsSession)")
        #expect(mysql("SET CHARACTER SET gbk") == "SET \(Self.keepsSession)")
        #expect(mysql("SET CHARSET latin1") == "SET \(Self.keepsSession)")
    }

    @Test("A routine section's client character set keeps the session's own instead")
    func mysqldumpRoutineCharacterSet() {
        #expect(mysql("/*!50003 SET character_set_client  = cp932 */")
            == "/*!50003 SET character_set_client  = @@session.character_set_client */")
        #expect(mysql("SET @@session.character_set_client = 'euckr'")
            == "SET @@session.character_set_client = @@session.character_set_client")
        #expect(mysql("SET SESSION character_set_client = big5, time_zone = '+00:00'")
            == "SET SESSION character_set_client = @@session.character_set_client, time_zone = '+00:00'")
    }

    @Test("Statements that already say UTF-8, restore a saved value, or change the server are left alone")
    func mysqlStatementsLeftAlone() {
        #expect(mysql("/*!50503 SET NAMES utf8mb4 */") == nil)
        #expect(mysql("SET NAMES utf8") == nil)
        #expect(mysql("SET NAMES DEFAULT") == nil)
        #expect(mysql("/*!50003 SET character_set_client = @saved_cs_client */") == nil)
        #expect(mysql("SET GLOBAL character_set_client = cp932") == nil)
        #expect(mysql("SET @@global.character_set_client = cp932") == nil)
        #expect(mysql("SET @@session.character_set_client = 33") == nil)
        #expect(mysql("SET time_zone = '+00:00'") == nil)
        #expect(mysql("INSERT INTO t VALUES ('SET NAMES cp932')") == nil)
    }

    @Test("A GLOBAL or PERSIST scope carries to the list's later assignments")
    func mysqlServerScopeCarriesAcrossTheList() {
        #expect(mysql("SET GLOBAL max_connections = 1000, character_set_client = cp932") == nil)
        #expect(mysql("SET PERSIST sql_mode = '', character_set_client = cp932") == nil)
        #expect(mysql("SET PERSIST_ONLY a = 1, character_set_client = cp932") == nil)
        #expect(mysql("SET GLOBAL a = 1, SESSION character_set_client = cp932")
            == "SET GLOBAL a = 1, SESSION character_set_client = @@session.character_set_client")
        #expect(mysql("SET GLOBAL a = 1, @@session.character_set_client = cp932")
            == "SET GLOBAL a = 1, @@session.character_set_client = @@session.character_set_client")
    }

    @Test("A pg_dump client encoding declares UTF-8 instead")
    func pgDumpClientEncoding() {
        #expect(postgres("SET client_encoding = 'SJIS'") == "SET client_encoding = 'UTF8'")
        #expect(postgres("SET client_encoding TO 'EUC_JP'") == "SET client_encoding TO 'UTF8'")
        #expect(postgres("SET SESSION client_encoding = BIG5") == "SET SESSION client_encoding = 'UTF8'")
        #expect(postgres("SET NAMES 'LATIN1'") == "SET NAMES 'UTF8'")
        #expect(postgres("SET client_encoding = 'UTF8'") == nil)
        #expect(postgres("SET client_encoding = 'unicode'") == nil)
        #expect(postgres("SET standard_conforming_strings = on") == nil)
    }

    @Test("Engines without a client encoding statement are left alone")
    func otherEnginesLeftAlone() {
        #expect(SQLClientEncodingRewriter.rewritten("SET NAMES cp932", family: .sqlite, grammar: TestGrammar.sqlite) == nil)
        #expect(SQLClientEncodingRewriter.rewritten("SET client_encoding = 'SJIS'", family: .sqlServer, grammar: TestGrammar.sqlServer) == nil)
    }
}
