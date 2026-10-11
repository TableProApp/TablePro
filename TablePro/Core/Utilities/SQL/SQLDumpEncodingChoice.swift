//
//  SQLDumpEncodingChoice.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar
import TableProTabularIO

internal enum SQLDumpEncodingChoice {
    private static let declarationScanLength = 65_536
    private static let declarationPattern = try? NSRegularExpression(pattern: [
        #"(?i)\A(?:\s+|--[^\n]*(?:\n|\z)|#[^\n]*(?:\n|\z)|/\*(?!M?!)[\s\S]*?\*/)*"#,
        #"(?:/\*M?!\d*\s*)?SET\s+(?:(?:SESSION|LOCAL)\s+)?"#,
        #"(?:NAMES|CHARACTER\s+SET|CHARSET|character_set_client\s*=|client_encoding\s*(?:=|TO))"#,
        #"\s*['"]?([A-Za-z0-9_-]+)"#
    ].joined())

    private static let declaredNames: [String: ImportEncoding] = [
        "UTF8": .utf8, "UTF8MB4": .utf8, "UTF8MB3": .utf8, "UNICODE": .utf8,
        "CP1252": .windows1252, "WIN1252": .windows1252, "WINDOWS1252": .windows1252,
        "LATIN1MYSQL": .windows1252, "LATIN1": .latin1, "ISO88591": .latin1,
        "ASCII": .ascii, "SQLASCII": .ascii,
        "CP932": .shiftJIS, "SJIS": .shiftJIS, "SHIFTJIS": .shiftJIS, "SHIFTJIS2004": .shiftJIS,
        "UJIS": .eucJP, "EUCJPMS": .eucJP, "EUCJP": .eucJP,
        "GBK": .gb18030, "GB2312": .gb18030, "GB18030": .gb18030, "EUCCN": .gb18030,
        "BIG5": .big5, "CP950": .big5,
        "EUCKR": .eucKR, "UHC": .eucKR, "CP949": .eucKR
    ]

    internal static func encoding(
        replacing selected: ImportEncoding,
        forPreview preview: Data,
        isWholeFile: Bool,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> ImportEncoding? {
        if let declared = declaredEncoding(in: preview, family: family, grammar: grammar) {
            guard declared != selected, decodes(preview, as: declared) else { return nil }
            return declared
        }
        let sniff = TabularEncodingDetector.sniff(preview, isWholeFile: isWholeFile)
        guard let detected = ImportEncoding(detected: sniff.encoding), detected != selected,
              !detected.canHideABackslashInsideACharacter, decodes(preview, as: detected) else {
            return nil
        }
        return detected
    }

    internal static func declaredEncoding(
        in preview: Data,
        family: TransactionEngineFamily,
        grammar: SQLLexicalGrammar
    ) -> ImportEncoding? {
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

    private static func decodes(_ preview: Data, as encoding: ImportEncoding) -> Bool {
        var decoder = SQLChunkDecoder(encoding: encoding.encoding)
        return decoder.decode(preview) != nil
    }
}
