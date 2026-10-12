//
//  MySQLErrorTextTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MySQLErrorTextTests {
    /// The `language` value measured on the 4.1.22 server.
    private static let koreanDirectory = "/usr/local/mysql/share/mysql/korean/"

    /// Measured on 4.1.22 for `SHOW FULL TABLES FROM ju_mijuit_new`.
    private static let syntaxError = wire(
        #"'SQL \xb1\xb8\xb9\xae\xbf\xa1 \xbf\xc0\xb7\xf9\xb0\xa1 \xc0\xd6\xbd\xc0\xb4\xcf\xb4\xd9.' \xbf\xa1\xb7\xaf \xb0\xb0\xc0\xbe\xb4\xcf\xb4\xd9. "#
            + #"('TABLES FROM `ju_mijuit_new`' \xb8\xed\xb7\xc9\xbe\xee \xb6\xf3\xc0\xce 1)"#
    )

    /// Measured on 4.1.22 for `SELECT * FROM 없는표`: an EUC-KR template around a UTF-8 identifier.
    private static let mixedNoSuchTable = wire(
        #"\xc5\xd7\xc0\xcc\xba\xed 'ju_mijuit_new.\xec\x97\x86\xeb\x8a\x94\xed\x91\x9c' \xb4\xc2 \xc1\xb8\xc0\xe7\xc7\xcf\xc1\xf6 \xbe\xca\xbd\xc0\xb4\xcf\xb4\xd9."#
    )

    /// Measured on 5.5.61 for the same statement.
    private static let utf8NoSuchTable = wire(
        #"\xed\x85\x8c\xec\x9d\xb4\xeb\xb8\x94 'ju_mijuit_new.\xec\x97\x86\xeb\x8a\x94\xed\x91\x9c' "#
            + #"\xeb\x8a\x94 \xec\xa1\xb4\xec\x9e\xac\xed\x95\x98\xec\xa7\x80 \xec\x95\x8a\xec\x8a\xb5\xeb\x8b\x88\xeb\x8b\xa4."#
    )

    private static let noSuchTableText = "테이블 'ju_mijuit_new.없는표' 는 존재하지 않습니다."

    private static func foundation(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// The probe prints each byte above 0x7F as `\xNN` and every other byte as itself.
    private static func wire(_ printed: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = Substring(printed)
        while let first = rest.first {
            if rest.hasPrefix("\\x"), let byte = UInt8(rest.dropFirst(2).prefix(2), radix: 16) {
                bytes.append(byte)
                rest = rest.dropFirst(4)
            } else {
                bytes.append(contentsOf: first.utf8)
                rest = rest.dropFirst()
            }
        }
        return bytes
    }

    private func decoded(_ bytes: [UInt8], language: String.Encoding?) -> String {
        bytes.withUnsafeBytes { MySQLErrorText.decode($0, language: language, encoding: .utf8) }
    }

    @Test("The language directory names the charset its messages are sent in")
    func languageDirectoryCharset() {
        let cases: [(directory: String, encoding: String.Encoding)] = [
            (Self.koreanDirectory, Self.foundation(.EUC_KR)),
            (#"C:\mysql\share\korean\"#, Self.foundation(.EUC_KR)),
            ("/usr/share/mysql/russian/", Self.foundation(.KOI8_R)),
            ("/usr/share/mysql/ukrainian/", Self.foundation(.KOI8_U)),
            ("/usr/share/mysql/japanese/", .japaneseEUC),
            ("/usr/share/mysql/japanese-sjis/", Self.foundation(.shiftJIS)),
            ("/usr/share/mysql/greek/", Self.foundation(.isoLatinGreek)),
            ("/usr/share/mysql/estonian/", Self.foundation(.isoLatin7)),
            ("/usr/share/mysql/czech/", .isoLatin2),
            ("/usr/share/mysql/serbian/", .windowsCP1250),
        ]

        for testCase in cases {
            #expect(MySQLErrorText.encoding(forLanguageDirectory: testCase.directory) == testCase.encoding, "\(testCase.directory)")
        }
    }

    @Test("A latin1 language or an unknown one has no charset of its own")
    func latin1AndUnknownLanguages() {
        for directory in ["/usr/share/mysql/english/", "/usr/share/mysql/german/", "/usr/share/mysql/klingon/", ""] {
            #expect(MySQLErrorText.encoding(forLanguageDirectory: directory) == nil, "\(directory)")
        }
    }

    @Test("The measured 4.1 syntax error reads in Korean")
    func koreanSyntaxError() {
        let korean = MySQLErrorText.encoding(forLanguageDirectory: Self.koreanDirectory)
        #expect(
            decoded(Self.syntaxError, language: korean)
                == "'SQL 구문에 오류가 있습니다.' 에러 같읍니다. ('TABLES FROM `ju_mijuit_new`' 명령어 라인 1)"
        )
    }

    /// Neither strict decode reads the whole message, so this is the run-by-run path.
    @Test("A Korean template around a UTF-8 table name reads both")
    func mixedMessage() {
        let korean = Self.foundation(.EUC_KR)
        #expect(String(bytes: Self.mixedNoSuchTable, encoding: .utf8) == nil)
        #expect(String(bytes: Self.mixedNoSuchTable, encoding: korean) == nil)
        #expect(decoded(Self.mixedNoSuchTable, language: korean) == Self.noSuchTableText)
    }

    /// 4.1.22's Korean `ER_DUP_KEYNAME`, `중복된 키 이름 : '%-.64s'`. Its `키` is `c5 b0`, which is also
    /// valid UTF-8 for `Ű`, so a run read UTF-8 first garbles the template.
    @Test("A template run that is also valid UTF-8 reads in the language charset")
    func languageCharsetFirstPerRun() {
        let message = Self.wire(#"\xc1\xdf\xba\xb9\xb5\xc8 \xc5\xb0 \xc0\xcc\xb8\xa7 : '"#) + Array("고객번호'".utf8)
        let korean = Self.foundation(.EUC_KR)

        #expect(String(bytes: message, encoding: .utf8) == nil)
        #expect(String(bytes: message, encoding: korean) == nil)
        #expect(decoded(message, language: korean) == "중복된 키 이름 : '고객번호'")
    }

    @Test("Measured 4.1 messages with ASCII identifiers read in Korean")
    func koreanTemplatesWithASCIIIdentifiers() {
        let korean = Self.foundation(.EUC_KR)
        let catalog = Self.wire(
            #"\xc5\xd7\xc0\xcc\xba\xed 'information_schema.TABLES' \xb4\xc2 \xc1\xb8\xc0\xe7\xc7\xcf\xc1\xf6 \xbe\xca\xbd\xc0\xb4\xcf\xb4\xd9."#
        )
        let column = Self.wire(#"Unknown \xc4\xae\xb7\xb3 'max_user_connections' in 'field list'"#)
        let english = Array("You may only use constant expressions with SET".utf8)

        #expect(decoded(catalog, language: korean) == "테이블 'information_schema.TABLES' 는 존재하지 않습니다.")
        #expect(decoded(column, language: korean) == "Unknown 칼럼 'max_user_connections' in 'field list'")
        #expect(decoded(english, language: korean) == "You may only use constant expressions with SET")
    }

    @Test("A 5.5 message is UTF-8 and reads the same with or without the language")
    func fiveFiveMessage() {
        #expect(decoded(Self.utf8NoSuchTable, language: nil) == Self.noSuchTableText)
        #expect(decoded(Self.utf8NoSuchTable, language: Self.foundation(.EUC_KR)) == Self.noSuchTableText)
    }

    @Test("Without a language a message reads as UTF-8, else as MySQL latin1")
    func noLanguageKeepsTheSessionDecoding() {
        let latin1 = Array("Duplicate entry 'caf".utf8) + [0xE9] + Array("' for key 1".utf8)
        let utf8 = Array("Table 'shop.заказы' doesn't exist".utf8)

        #expect(decoded(latin1, language: nil) == "Duplicate entry 'café' for key 1")
        #expect(decoded(utf8, language: nil) == "Table 'shop.заказы' doesn't exist")
    }

    @Test("A NUL-terminated message reads the same as its bytes")
    func cStringMessage() {
        let terminated = Self.mixedNoSuchTable + [0]
        let text = terminated.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { characters in
                characters.baseAddress.map {
                    MySQLErrorText.decode(cString: $0, language: Self.foundation(.EUC_KR), encoding: .utf8)
                }
            }
        }
        #expect(text == Self.noSuchTableText)
    }

    /// KOI8-R maps every byte, so the whole message decodes and the UTF-8 name inside it never reaches
    /// the run-by-run path. The template is the 4.1.22 Russian `ER_NO_SUCH_TABLE`.
    @Test("Known limit: a UTF-8 table name inside a KOI8-R message reads as KOI8-R")
    func knownLimitKOI8R() {
        let message = Self.wire(#"\xf4\xc1\xc2\xcc\xc9\xc3\xc1 'shop."#)
            + Array("заказы".utf8)
            + Self.wire(#"' \xce\xc5 \xd3\xd5\xdd\xc5\xd3\xd4\xd7\xd5\xc5\xd4"#)
        let russian = MySQLErrorText.encoding(forLanguageDirectory: "/usr/share/mysql/russian/")

        #expect(decoded(message, language: russian) == "Таблица 'shop.п╥п╟п╨п╟п╥я▀' не существует")
    }

    /// UTF-8 `é` is `c3 a9`, which is also a valid EUC-KR pair, so the whole message decodes as EUC-KR.
    @Test("Known limit: café inside an EUC-KR message reads as EUC-KR")
    func knownLimitAccentInEUCKR() {
        let message = Self.wire(#"\xc5\xd7\xc0\xcc\xba\xed 'ju_mijuit_new."#)
            + Array("café".utf8)
            + Self.wire(#"' \xb4\xc2 \xc1\xb8\xc0\xe7\xc7\xcf\xc1\xf6 \xbe\xca\xbd\xc0\xb4\xcf\xb4\xd9."#)

        #expect(decoded(message, language: Self.foundation(.EUC_KR)) == "테이블 'ju_mijuit_new.caf챕' 는 존재하지 않습니다.")
    }
}
