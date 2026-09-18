import Foundation

internal struct GoogleDERElement: Sendable, Equatable {
    let tag: UInt8
    let content: ArraySlice<UInt8>
}

internal struct GoogleDERReader: Sendable {
    enum Tag {
        static let integer: UInt8 = 0x02
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let sequence: UInt8 = 0x30
    }

    private static let maximumLengthOctets = 4
    private static let highTagNumberMask: UInt8 = 0x1F

    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    var isAtEnd: Bool {
        offset >= bytes.endIndex
    }

    mutating func read(expecting tag: UInt8) throws -> GoogleDERElement {
        let element = try readElement()
        guard element.tag == tag else { throw GoogleAuthError.malformedPrivateKey }
        return element
    }

    mutating func readElement() throws -> GoogleDERElement {
        let tag = try nextByte()
        guard tag & Self.highTagNumberMask != Self.highTagNumberMask else {
            throw GoogleAuthError.malformedPrivateKey
        }
        let length = try readLength()
        guard length <= bytes.endIndex - offset else { throw GoogleAuthError.malformedPrivateKey }
        let content = bytes[offset..<(offset + length)]
        offset += length
        return GoogleDERElement(tag: tag, content: content)
    }

    private mutating func nextByte() throws -> UInt8 {
        guard offset < bytes.endIndex else { throw GoogleAuthError.malformedPrivateKey }
        let byte = bytes[offset]
        offset += 1
        return byte
    }

    private mutating func readLength() throws -> Int {
        let first = try nextByte()
        guard first & 0x80 != 0 else { return Int(first) }
        let octetCount = Int(first & 0x7F)
        guard octetCount > 0, octetCount <= Self.maximumLengthOctets else {
            throw GoogleAuthError.malformedPrivateKey
        }
        var length = 0
        for _ in 0..<octetCount {
            length = (length << 8) | Int(try nextByte())
        }
        return length
    }
}
