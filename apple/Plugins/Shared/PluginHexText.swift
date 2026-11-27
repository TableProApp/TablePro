//
//  PluginHexText.swift
//  TablePro
//

import Foundation

nonisolated enum PluginHexText {
    private static let digits = Array("0123456789ABCDEF".utf8)

    static func uppercase(_ data: Data) -> String {
        let digits = Self.digits
        return String(unsafeUninitializedCapacity: data.count * 2) { text in
            var length = 0
            for byte in data {
                text[length] = digits[Int(byte >> 4)]
                text[length + 1] = digits[Int(byte & 0x0F)]
                length += 2
            }
            return length
        }
    }

    static func appendUppercase(_ byte: UInt8, to text: inout [UInt8]) {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0x0F)])
    }
}
