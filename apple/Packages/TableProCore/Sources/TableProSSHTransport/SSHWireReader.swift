import Foundation

// RFC 4251, 5.
struct SSHWireReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    mutating func bytes(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= data.count - offset else { return nil }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func byte() -> UInt8? {
        bytes(1)?.first
    }

    mutating func uint32() -> Int? {
        bytes(4)?.reduce(0) { ($0 << 8) | Int($1) }
    }

    mutating func field() -> ArraySlice<UInt8>? {
        guard let length = uint32() else { return nil }
        return bytes(length)
    }

    mutating func string() -> String? {
        field().flatMap { String(bytes: $0, encoding: .utf8) }
    }

    mutating func nameList() -> [String]? {
        string().map { $0.split(separator: ",").map(String.init) }
    }
}
