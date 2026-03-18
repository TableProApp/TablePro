//
//  Base32.swift
//  TablePro
//

import Foundation

internal enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 255, count: 128)
        for (index, char) in alphabet.enumerated() {
            let asciiValue = Int(char.asciiValue ?? 0)
            table[asciiValue] = UInt8(index)
            // Lowercase mapping
            if let lower = Character(char.lowercased()).asciiValue {
                table[Int(lower)] = UInt8(index)
            }
        }
        return table
    }()

    /// Decode a base32-encoded string to Data.
    /// - Parameter string: Base32-encoded string (case-insensitive, padding optional)
    /// - Returns: Decoded data, or nil if invalid
    static func decode(_ string: String) -> Data? {
        // Strip whitespace, dashes, and padding
        let cleaned = string.filter { char in
            char != " " && char != "-" && char != "=" && char != "\n" && char != "\r" && char != "\t"
        }

        if cleaned.isEmpty {
            return Data()
        }

        var output = Data()
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for char in cleaned {
            guard let ascii = char.asciiValue, ascii < 128 else {
                return nil
            }

            let value = decodeTable[Int(ascii)]
            if value == 255 {
                return nil
            }

            buffer = (buffer << 5) | UInt64(value)
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                let byte = UInt8((buffer >> bitsLeft) & 0xFF)
                output.append(byte)
            }
        }

        return output
    }
}
