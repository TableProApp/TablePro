//
//  MySQLCharacterSet.swift
//  MySQLDriverPlugin
//

import CoreFoundation
import Foundation

nonisolated internal struct MySQLCharacterSet: Hashable, Sendable {
    static let utf8mb4 = MySQLCharacterSet(serverName: "utf8mb4")
    static let latin1 = MySQLCharacterSet(serverName: "latin1")

    let name: String
    private let decoding: Decoding

    init(serverName: String) {
        let normalized = serverName.trimmingCharacters(in: .whitespaces).lowercased()
        name = normalized == "utf8" ? "utf8mb3" : normalized
        decoding = Self.decoding(forName: name)
    }

    func decode(_ bytes: UnsafeRawBufferPointer) -> String {
        switch decoding {
        case .utf8:
            return Self.decodeUTF8ReplacingInvalid(bytes)
        case .utf8OrMySQLLatin1:
            return Self.decodeUTF8OrMySQLLatin1(bytes)
        case .foundation(let encoding, let isSingleByte):
            return Self.decode(bytes, encoding: encoding, isSingleByte: isSingleByte)
        }
    }

    static func decodeUTF8OrMySQLLatin1(_ bytes: UnsafeRawBufferPointer) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) {
            return text
        }
        return MySQLLatin1.decode(bytes)
    }

    static func decodeUTF8ReplacingInvalid(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    static var singleByteDecodedNames: [String] {
        Array(singleByteEncodings.keys).sorted()
    }

    static var multiByteDecodedNames: [String] {
        Array(multiByteEncodings.keys).sorted()
    }

    private enum Decoding: Hashable, Sendable {
        case utf8
        case utf8OrMySQLLatin1
        case foundation(String.Encoding, isSingleByte: Bool)
    }

    private static let utf8Names: Set<String> = ["utf8mb4", "utf8mb3", "ascii", "binary"]

    private static func decoding(forName name: String) -> Decoding {
        if utf8Names.contains(name) { return .utf8 }
        if name == "latin1" { return .utf8OrMySQLLatin1 }
        if let encoding = singleByteEncodings[name] { return .foundation(encoding, isSingleByte: true) }
        if let encoding = multiByteEncodings[name] { return .foundation(encoding, isSingleByte: false) }
        return .utf8
    }

    private static let singleByteEncodings: [String: String.Encoding] = [
        "latin2": .isoLatin2,
        "cp1250": .windowsCP1250,
        "cp1251": .windowsCP1251,
        "cp1256": encoding(.windowsArabic),
        "cp1257": encoding(.windowsBalticRim),
        "cp850": encoding(.dosLatin1),
        "cp852": encoding(.dosLatin2),
        "latin5": encoding(.isoLatin5),
        "macce": encoding(.macCentralEurRoman),
        "macroman": .macOSRoman
    ]

    private static let multiByteEncodings: [String: String.Encoding] = [
        "cp932": .shiftJIS,
        "gbk": encoding(.GBK_95),
        "gb2312": encoding(.EUC_CN),
        "gb18030": encoding(.GB_18030_2000),
        "ucs2": .utf16BigEndian,
        "utf16": .utf16BigEndian,
        "utf16le": .utf16LittleEndian,
        "utf32": .utf32BigEndian
    ]

    private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private static func decode(
        _ bytes: UnsafeRawBufferPointer,
        encoding: String.Encoding,
        isSingleByte: Bool
    ) -> String {
        if let text = String(bytes: bytes, encoding: encoding) {
            return text
        }
        guard isSingleByte else {
            return decodeUTF8ReplacingInvalid(bytes)
        }
        return bytes.reduce(into: "") { text, byte in
            text += String(bytes: [byte], encoding: encoding) ?? "\u{FFFD}"
        }
    }
}
