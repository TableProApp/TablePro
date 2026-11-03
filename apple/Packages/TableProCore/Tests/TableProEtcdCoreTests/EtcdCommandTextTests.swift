import Foundation
import Testing

@testable import TableProEtcdCore

struct EtcdCommandTextRoundTripTests {
    @Test("every byte value survives quote then tokenize")
    func everyByteSurvives() {
        for value in UInt8.min ... UInt8.max {
            let argument = Data([value])
            #expect(EtcdCommandText.tokenize(EtcdCommandText.quoted(argument)) == [argument])
        }
    }

    @Test("binary keys survive quote then tokenize")
    func blobsSurvive() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextByte() -> UInt8 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        for length in 1 ... 200 {
            let blob = Data((0 ..< length).map { _ in nextByte() })
            #expect(EtcdCommandText.tokenize(EtcdCommandText.quoted(blob)) == [blob])
        }
    }

    @Test("a key that is not UTF-8 keeps its bytes")
    func nonUTF8Key() {
        let key = Data([0x2F, 0x61, 0xFF, 0xFE, 0x2F, 0x62])
        let quoted = EtcdCommandText.quoted(key)
        #expect(quoted == #""/a\xff\xfe/b""#)
        #expect(EtcdCommandText.tokenize("del \(quoted)") == [Data("del".utf8), key])
    }

    @Test("a leading byte order mark is part of the key")
    func byteOrderMark() {
        let key = Data([0xEF, 0xBB, 0xBF, 0x61])
        #expect(EtcdCommandText.text(key)?.unicodeScalars.first == "\u{FEFF}")
        #expect(EtcdCommandText.tokenize(EtcdCommandText.quoted(key)) == [key])
    }

    @Test("an empty argument survives")
    func emptySurvives() {
        #expect(EtcdCommandText.quoted(Data()) == "\"\"")
        #expect(EtcdCommandText.tokenize("get \"\" --prefix") == [Data("get".utf8), Data(), Data("--prefix".utf8)])
    }

    @Test("every character a trim, the tokenizer or a text field drops survives at either edge of a key")
    func edgeCharactersSurvive() {
        var checked = 0
        for value in UInt32(0) ... 0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let dropped = EtcdCommandText.isBlank(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.isDefaultIgnorableCodePoint
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .control
            guard dropped else { continue }
            checked += 1
            var key = String.UnicodeScalarView()
            key.append(scalar)
            key.append(contentsOf: "key".unicodeScalars)
            key.append(scalar)
            let argument = Data(String(key).utf8)
            let line = "del " + EtcdCommandText.quoted(argument) + " \n"
            #expect(EtcdCommandText.tokenize(EtcdCommandText.trimmed(line)) == [Data("del".utf8), argument])
            let hostTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(EtcdCommandText.tokenize(hostTrimmed) == [Data("del".utf8), argument])
        }
        #expect(checked > 4_000)
    }
}

struct EtcdCommandTextQuotingTests {
    @Test("a plain key stays bare")
    func plainKeyIsBare() {
        #expect(EtcdCommandText.quoted("/app/config") == "/app/config")
    }

    @Test("non-ASCII text stays readable")
    func unicodeStaysReadable() {
        #expect(EtcdCommandText.quoted("/app/café") == "/app/café")
    }

    @Test("a zero width space is quoted, since a whitespace trim drops it")
    func zeroWidthSpaceIsQuoted() {
        #expect(EtcdCommandText.quoted("foo\u{200B}") == "\"foo\u{200B}\"")
    }

    @Test("a key with a space or a quote is quoted and escaped")
    func spacesAndQuotes() {
        #expect(EtcdCommandText.quoted("a b") == "\"a b\"")
        #expect(EtcdCommandText.quoted("say \"hi\"") == #""say \"hi\"""#)
        #expect(EtcdCommandText.quoted("it's") == "\"it's\"")
    }

    @Test("a control character is written as a byte escape")
    func controlsAreEscaped() {
        #expect(EtcdCommandText.quoted("a\u{01}b\nc") == #""a\x01b\nc""#)
    }
}

struct EtcdCommandTextCommandTests {
    @Test("a plain command keeps etcdctl's argument order")
    func plainOrder() {
        let line = EtcdCommandText.command("get", arguments: [Data("/app/".utf8)], flags: ["--prefix"])
        #expect(line == "get /app/ --prefix")
    }

    @Test("a key that starts with -- follows the end of the flags")
    func dashedKeyFollowsEndOfFlags() {
        let line = EtcdCommandText.command(
            "put", arguments: [Data("--lease".utf8), Data("v".utf8)], flags: ["--lease=0x7b"]
        )
        #expect(line == "put --lease=0x7b -- --lease v")
        #expect(EtcdCommandText.tokenize(line).count == 5)
    }
}

struct EtcdCommandTextTokenizerTests {
    @Test("a hex escape inside quotes is one byte")
    func hexEscape() {
        #expect(EtcdCommandText.tokenize(#""\xff\x00A""#) == [Data([0xFF, 0x00, 0x41])])
        #expect(EtcdCommandText.tokenize(#"'\x2F'"#) == [Data("/".utf8)])
    }

    @Test("a hex escape without two hex digits stays as written")
    func incompleteHexEscape() {
        #expect(EtcdCommandText.tokenize(#""\xZZ""#) == [Data(#"\xZZ"#.utf8)])
        #expect(EtcdCommandText.tokenize(#""a\x4""#) == [Data(#"a\x4"#.utf8)])
        #expect(EtcdCommandText.tokenize(#""\x""#) == [Data(#"\x"#.utf8)])
    }

    @Test("a backslash outside quotes is a literal character")
    func backslashOutsideQuotes() {
        #expect(EtcdCommandText.tokenize(#"C:\xff"#) == [Data(#"C:\xff"#.utf8)])
    }

    @Test("the trim drops only Unicode whitespace")
    func trimDropsOnlyWhitespace() {
        #expect(EtcdCommandText.trimmed(" \u{3000}get k\n") == "get k")
        #expect(EtcdCommandText.trimmed("del foo\u{200B}") == "del foo\u{200B}")
        #expect(EtcdCommandText.trimmed(" \t ").isEmpty)
    }
}
