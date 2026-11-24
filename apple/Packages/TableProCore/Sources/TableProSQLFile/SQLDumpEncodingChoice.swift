import Foundation
import TableProSQLGrammar
import TableProTabularIO

public enum SQLDumpEncodingChoice {
    private static let declarationScanLength = 65_536
    private static let declarationPattern = try? NSRegularExpression(pattern: [
        #"(?i)\A(?:\s+|--[^\n]*(?:\n|\z)|#[^\n]*(?:\n|\z)|/\*(?!M?!)[\s\S]*?\*/)*"#,
        #"(?:/\*M?!\d*\s*)?SET\s+(?:(?:SESSION|LOCAL)\s+)?"#,
        #"(?:NAMES|CHARACTER\s+SET|CHARSET|character_set_client\s*=|client_encoding\s*(?:=|TO))"#,
        #"\s*['"]?([A-Za-z0-9_-]+)"#
    ].joined())

    private static let declaredNames: [String: String.Encoding] = [
        "UTF8": .utf8, "UTF8MB4": .utf8, "UTF8MB3": .utf8, "UNICODE": .utf8,
        "CP1252": .windowsCP1252, "WIN1252": .windowsCP1252, "WINDOWS1252": .windowsCP1252,
        "LATIN1MYSQL": .windowsCP1252, "LATIN1": .isoLatin1, "ISO88591": .isoLatin1,
        "ASCII": .ascii, "SQLASCII": .ascii,
        "CP932": shiftJIS, "SJIS": shiftJIS, "SHIFTJIS": shiftJIS, "SHIFTJIS2004": shiftJIS,
        "UJIS": eucJP, "EUCJPMS": eucJP, "EUCJP": eucJP,
        "GBK": gb18030, "GB2312": gb18030, "GB18030": gb18030, "EUCCN": gb18030,
        "BIG5": big5, "CP950": big5,
        "EUCKR": eucKR, "UHC": eucKR, "CP949": eucKR
    ]

    private static let shiftJIS = TabularTextEncoding.shiftJIS.foundationEncoding
    private static let eucJP = TabularTextEncoding.eucJP.foundationEncoding
    private static let gb18030 = TabularTextEncoding.gb18030.foundationEncoding
    private static let big5 = TabularTextEncoding.big5.foundationEncoding
    private static let eucKR = TabularTextEncoding.eucKR.foundationEncoding

    // A trail byte of these can be 0x5C, so a guess at one could end a literal early inside a character.
    private static let hidesABackslashInsideACharacter: Set<TabularTextEncoding> = [.shiftJIS, .gb18030, .big5]

    public static func encoding(
        replacing selected: String.Encoding,
        forPreview preview: Data,
        isWholeFile: Bool,
        family: SQLDumpFamily,
        grammar: SQLLexicalGrammar
    ) -> String.Encoding? {
        if let declared = declaredEncoding(in: preview, family: family, grammar: grammar) {
            guard declared != selected, previewDecodes(preview, as: declared, isWholeFile: isWholeFile) else { return nil }
            return declared
        }
        let detected = TabularEncodingDetector.sniff(preview, isWholeFile: isWholeFile).encoding
        guard detected.foundationEncoding != selected, !hidesABackslashInsideACharacter.contains(detected),
              previewDecodes(preview, as: detected.foundationEncoding, isWholeFile: isWholeFile) else {
            return nil
        }
        return detected.foundationEncoding
    }

    public static func declaredEncoding(
        in preview: Data,
        family: SQLDumpFamily,
        grammar: SQLLexicalGrammar
    ) -> String.Encoding? {
        guard let declarationPattern,
              let head = String(data: preview.prefix(declarationScanLength), encoding: .isoLatin1) else {
            return nil
        }
        for statement in SQLStatementScanner.allStatements(in: head, grammar: grammar) {
            let text = statement as NSString
            guard let match = declarationPattern.firstMatch(in: statement, range: NSRange(location: 0, length: text.length)) else {
                continue
            }
            let name = text.substring(with: match.range(at: 1)).uppercased().filter { $0.isLetter || $0.isNumber }
            let key = name == "LATIN1" && family == .mysql ? "LATIN1MYSQL" : name
            if let encoding = declaredNames[key] {
                return encoding
            }
        }
        return nil
    }

    // The decoded preview, or nil when it does not read as `encoding`. A whole file has no next chunk, so bytes held
    // back as the start of a split character never decode.
    public static func decodedPreview(_ preview: Data, as encoding: String.Encoding, isWholeFile: Bool) -> String? {
        var decoder = SQLChunkDecoder(encoding: encoding)
        guard let text = decoder.decode(preview), !(isWholeFile && decoder.hasPendingBytes) else { return nil }
        return text
    }

    public static func previewDecodes(_ preview: Data, as encoding: String.Encoding, isWholeFile: Bool) -> Bool {
        decodedPreview(preview, as: encoding, isWholeFile: isWholeFile) != nil
    }
}
