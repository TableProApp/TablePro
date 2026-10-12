//
//  MySQLErrorText.swift
//  MySQLDriverPlugin
//

import CoreFoundation
import Foundation

/// Error text from a server before 5.5, which sends the message template in the charset of its error
/// language and the identifiers inside it in UTF-8, whatever `SET NAMES` asked for.
nonisolated internal enum MySQLErrorText {
    /// The charset each error language's `errmsg.txt` declares, from 4.1.22's per-language files and
    /// the `languages` header of 5.0.96 and 5.1.73. The latin1 languages are absent: the session
    /// decoder already reads latin1.
    private static let languageEncodings: [String: String.Encoding] = [
        "czech": .isoLatin2,
        "hungarian": .isoLatin2,
        "polish": .isoLatin2,
        "romanian": .isoLatin2,
        "slovak": .isoLatin2,
        "serbian": .windowsCP1250,
        "estonian": encoding(.isoLatin7),
        "greek": encoding(.isoLatinGreek),
        "japanese": .japaneseEUC,
        "japanese-sjis": encoding(.shiftJIS),
        "korean": encoding(.EUC_KR),
        "russian": encoding(.KOI8_R),
        "ukrainian": encoding(.KOI8_U),
    ]

    /// The value of the `language` variable is the error message directory, such as
    /// `/usr/local/mysql/share/mysql/korean/` or `C:\mysql\share\korean\`.
    static func encoding(forLanguageDirectory directory: String) -> String.Encoding? {
        let name = directory
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return name.flatMap { languageEncodings[$0] }
    }

    /// Strict UTF-8 first, because no non-ASCII template in any language is valid UTF-8 (checked over
    /// every 5.0.96 template). Then the language charset over the whole message. A message that mixes
    /// the two, measured on 4.1.22 as an EUC-KR template around a UTF-8 table name, fails both, so it
    /// is decoded run by run between ASCII bytes, language charset first: ten Korean template runs are
    /// valid UTF-8 by accident.
    static func decode(
        _ bytes: UnsafeRawBufferPointer,
        language: String.Encoding?,
        encoding: MySQLConnectionEncoding
    ) -> String {
        guard let language else { return mysqlSessionText(bytes, encoding: encoding) }
        if let text = String(bytes: bytes, encoding: .utf8) {
            return encoding.presentedText(text)
        }
        if let text = String(bytes: bytes, encoding: language) {
            return text
        }
        return decodeRuns(bytes, language: language)
    }

    static func decode(
        cString: UnsafePointer<CChar>,
        language: String.Encoding?,
        encoding: MySQLConnectionEncoding
    ) -> String {
        decode(UnsafeRawBufferPointer(start: cString, count: strlen(cString)), language: language, encoding: encoding)
    }

    private static func decodeRuns(_ bytes: UnsafeRawBufferPointer, language: String.Encoding) -> String {
        var text = ""
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let isASCII = bytes[index] < 0x80
            var end = index
            while end < bytes.endIndex, (bytes[end] < 0x80) == isASCII {
                end += 1
            }
            let run = UnsafeRawBufferPointer(rebasing: bytes[index..<end])
            if isASCII {
                text += String(decoding: run, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            } else {
                text += String(bytes: run, encoding: language)
                    ?? String(bytes: run, encoding: .utf8)
                    ?? MySQLLatin1.decode(run)
            }
            index = end
        }
        return text
    }

    private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
