//
//  JSONTextDecoder.swift
//  JSONImportPlugin
//

import Foundation

// The five encodings `JSONSerialization` reads, with or without a byte order mark.
enum JSONTextEncoding: Equatable {
    case utf8
    case utf16BigEndian
    case utf16LittleEndian
    case utf32BigEndian
    case utf32LittleEndian

    var unitWidth: Int {
        switch self {
        case .utf8: return 1
        case .utf16BigEndian, .utf16LittleEndian: return 2
        case .utf32BigEndian, .utf32LittleEndian: return 4
        }
    }

    // RFC 4627, section 3: the first two characters are ASCII, so the zero bytes in the first four
    // name the encoding when no byte order mark does.
    static func detect(_ head: some Collection<UInt8>) -> (encoding: JSONTextEncoding, markLength: Int) {
        let bytes = Array(head.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        guard bytes.count >= 2 else { return (.utf8, 0) }
        if bytes.count >= 4 {
            if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0 { return (.utf32BigEndian, 0) }
            if bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 { return (.utf32LittleEndian, 0) }
        }
        if bytes[0] == 0 { return (.utf16BigEndian, 0) }
        if bytes[1] == 0 { return (.utf16LittleEndian, 0) }
        return (.utf8, 0)
    }
}

// Turns UTF-16 or UTF-32 text into UTF-8 a chunk at a time. A code unit, or a surrogate pair, that a
// chunk cuts in two waits for the next chunk.
struct JSONTextDecoder {
    let encoding: JSONTextEncoding
    private var pending: [UInt8] = []

    init(encoding: JSONTextEncoding) {
        self.encoding = encoding
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    mutating func utf8(from chunk: Data) throws -> [UInt8] {
        guard encoding != .utf8 else { return Array(chunk) }
        pending.append(contentsOf: chunk)
        var usable = pending.count - pending.count % encoding.unitWidth
        var output: [UInt8] = []
        output.reserveCapacity(usable)
        let failed: Bool
        switch encoding {
        case .utf8:
            return Array(chunk)
        case .utf16BigEndian, .utf16LittleEndian:
            var units: [UInt16] = []
            units.reserveCapacity(usable / 2)
            var index = 0
            while index < usable {
                let first = UInt16(pending[index])
                let second = UInt16(pending[index + 1])
                units.append(encoding == .utf16BigEndian ? first << 8 | second : second << 8 | first)
                index += 2
            }
            if let last = units.last, (0xD800...0xDBFF).contains(last) {
                units.removeLast()
                usable -= 2
            }
            failed = transcode(units.makeIterator(), from: UTF16.self, to: UTF8.self, stoppingOnError: true) {
                output.append($0)
            }
        case .utf32BigEndian, .utf32LittleEndian:
            var units: [UInt32] = []
            units.reserveCapacity(usable / 4)
            var index = 0
            while index < usable {
                let bytes = pending[index..<(index + 4)].map(UInt32.init)
                units.append(encoding == .utf32BigEndian
                    ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
                    : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
                index += 4
            }
            failed = transcode(units.makeIterator(), from: UTF32.self, to: UTF8.self, stoppingOnError: true) {
                output.append($0)
            }
        }
        if failed { throw JSONDocumentError.invalidText }
        pending.removeSubrange(0..<usable)
        return output
    }

    // At the end of the file nothing may still wait for the rest of a character.
    func finish() throws {
        guard pending.isEmpty else { throw JSONDocumentError.invalidText }
    }
}
