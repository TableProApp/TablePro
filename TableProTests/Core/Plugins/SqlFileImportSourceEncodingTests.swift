//
//  SqlFileImportSourceEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTabularIO
import Testing

struct SqlFileImportSourceEncodingTests {
    private func statements(of bytes: Data, encoding: String.Encoding, family: TransactionEngineFamily) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SqlFileImportSourceEncodingTests-\(UUID().uuidString).sql")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let grammar = family == .mysql ? TestGrammar.mysql : TestGrammar.postgres
        let source = SqlFileImportSource(url: url, encoding: encoding, grammar: grammar, family: family)
        var result: [String] = []
        for try await (statement, _) in try await source.statements() {
            result.append(statement)
        }
        return result
    }

    @Test("A Shift JIS mysqldump keeps the session's UTF-8 client character set and its text decoded")
    func shiftJISMysqldump() async throws {
        let dump = "/*!40101 SET NAMES cp932 */;\nINSERT INTO t VALUES ('日本語 髙橋');\n"
        let bytes = try #require(dump.data(using: .shiftJIS, allowLossyConversion: false))
        let result = try await statements(of: bytes, encoding: ImportEncoding.shiftJIS.encoding, family: .mysql)
        #expect(result == [
            "/*!40101 SET character_set_client = @@session.character_set_client */",
            "INSERT INTO t VALUES ('日本語 髙橋')"
        ])
    }

    @Test("A Shift JIS pg_dump runs with a UTF-8 client encoding")
    func shiftJISPgDump() async throws {
        let dump = "SET client_encoding = 'SJIS';\nINSERT INTO t VALUES ('日本語');\n"
        let bytes = try #require(dump.data(using: .shiftJIS, allowLossyConversion: false))
        let result = try await statements(of: bytes, encoding: ImportEncoding.shiftJIS.encoding, family: .postgres)
        #expect(result.first == "SET client_encoding = 'UTF8'")
    }

    @Test("A UTF-8 file keeps its own character set statement, since its bytes go to the server unchanged")
    func utf8FileKeepsItsDeclaration() async throws {
        let dump = "/*!40101 SET NAMES latin1 */;\nINSERT INTO t VALUES ('é');\n"
        let result = try await statements(of: Data(dump.utf8), encoding: .utf8, family: .mysql)
        #expect(result.first == "/*!40101 SET NAMES latin1 */")
    }

    @Test("Each East Asian import encoding matches the detector's encoding")
    func importEncodingsFollowTheDetector() {
        let pairs: [(ImportEncoding, TabularTextEncoding)] = [
            (.shiftJIS, .shiftJIS), (.eucJP, .eucJP), (.gb18030, .gb18030), (.big5, .big5), (.eucKR, .eucKR),
            (.utf8, .utf8), (.utf16LittleEndian, .utf16LittleEndian), (.windows1252, .windows1252), (.latin1, .isoLatin1)
        ]
        for (option, tabular) in pairs {
            #expect(ImportEncoding(detected: tabular) == option)
            #expect(option.encoding == tabular.foundationEncoding)
        }
        #expect(ImportEncoding.shiftJIS.rawValue == "Shift_JIS")
        #expect(ImportEncoding.shiftJIS.label == "Shift JIS")
    }

    @Test("A Latin-1 mysqldump keeps its binary column bytes and its accented text")
    func latin1MysqldumpWithBinaryData() async throws {
        let bytes = Array("/*!40101 SET NAMES latin1 */;\nINSERT INTO t VALUES ('Caf".utf8) + [0xE9]
            + Array("', _binary'".utf8) + [0x00, 0xFF] + Array("');\n".utf8)
        let result = try await statements(of: Data(bytes), encoding: .isoLatin1, family: .mysql)
        #expect(result == [
            "/*!40101 SET character_set_client = @@session.character_set_client */",
            "INSERT INTO t VALUES ('Café', X'00FF')"
        ])
    }

    @Test("A Shift JIS dump holding binary data stops at that line instead of storing different bytes")
    func shiftJISMysqldumpWithBinaryDataIsRefused() async throws {
        let dump = "INSERT INTO t VALUES (1);\nINSERT INTO t VALUES (_binary'髙');\n"
        let bytes = try #require(dump.data(using: .shiftJIS))
        await #expect(throws: SqlFileImportError.unrecoverableBinaryLiteral(
            line: 2,
            encoding: String.localizedName(of: .shiftJIS)
        )) {
            _ = try await statements(of: bytes, encoding: .shiftJIS, family: .mysql)
        }
    }
}
