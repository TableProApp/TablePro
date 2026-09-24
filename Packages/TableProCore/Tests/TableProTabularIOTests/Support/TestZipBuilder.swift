import Compression
import Foundation

struct TestZipBuilder {
    enum Method {
        case stored
        case deflate
        case unsupported
    }

    private struct File {
        let path: String
        let body: Data
        let method: Method
    }

    private var files: [File] = []
    var usesDataDescriptors = false
    var usesZip64Extra = false
    var zip64OffsetOverride: UInt64?

    mutating func add(_ path: String, _ text: String, method: Method = .deflate) {
        add(path, data: Data(text.utf8), method: method)
    }

    mutating func add(_ path: String, data: Data, method: Method = .deflate) {
        files.append(File(path: path, body: data, method: method))
    }

    func build() -> Data {
        var output = Data()
        var directory = Data()
        for file in files {
            let offset = output.count
            let name = Data(file.path.utf8)
            let payload = file.method == .deflate ? Self.deflate(file.body) : file.body
            let checksum = Self.crc32(file.body)
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.append(Self.uint16(20))
            output.append(Self.uint16(usesDataDescriptors ? 0x0008 : 0))
            output.append(Self.uint16(methodCode(file.method)))
            output.append(Self.uint32(0))
            output.append(Self.uint32(usesDataDescriptors ? 0 : checksum))
            output.append(Self.uint32(usesDataDescriptors ? 0 : UInt32(payload.count)))
            output.append(Self.uint32(usesDataDescriptors ? 0 : UInt32(file.body.count)))
            output.append(Self.uint16(UInt16(name.count)))
            output.append(Self.uint16(0))
            output.append(name)
            output.append(payload)
            if usesDataDescriptors {
                output.append(contentsOf: [0x50, 0x4B, 0x07, 0x08])
                output.append(Self.uint32(checksum))
                output.append(Self.uint32(UInt32(payload.count)))
                output.append(Self.uint32(UInt32(file.body.count)))
            }
            directory.append(centralRecord(file, name: name, payload: payload, checksum: checksum, offset: offset))
        }
        let directoryOffset = output.count
        output.append(directory)
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.append(Self.uint16(0))
        output.append(Self.uint16(0))
        output.append(Self.uint16(UInt16(files.count)))
        output.append(Self.uint16(UInt16(files.count)))
        output.append(Self.uint32(UInt32(directory.count)))
        output.append(Self.uint32(UInt32(directoryOffset)))
        output.append(Self.uint16(0))
        return output
    }

    private func centralRecord(_ file: File, name: Data, payload: Data, checksum: UInt32, offset: Int) -> Data {
        var record = Data()
        var extra = Data()
        if usesZip64Extra {
            extra.append(Self.uint16(0x0001))
            extra.append(Self.uint16(24))
            extra.append(Self.uint64(UInt64(file.body.count)))
            extra.append(Self.uint64(UInt64(payload.count)))
            extra.append(Self.uint64(zip64OffsetOverride ?? UInt64(offset)))
        }
        let saturated: UInt32 = 0xFFFF_FFFF
        record.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        record.append(Self.uint16(45))
        record.append(Self.uint16(20))
        record.append(Self.uint16(usesDataDescriptors ? 0x0008 : 0))
        record.append(Self.uint16(methodCode(file.method)))
        record.append(Self.uint32(0))
        record.append(Self.uint32(checksum))
        record.append(Self.uint32(usesZip64Extra ? saturated : UInt32(payload.count)))
        record.append(Self.uint32(usesZip64Extra ? saturated : UInt32(file.body.count)))
        record.append(Self.uint16(UInt16(name.count)))
        record.append(Self.uint16(UInt16(extra.count)))
        record.append(Self.uint16(0))
        record.append(Self.uint16(0))
        record.append(Self.uint16(0))
        record.append(Self.uint32(0))
        record.append(Self.uint32(usesZip64Extra ? saturated : UInt32(offset)))
        record.append(name)
        record.append(extra)
        return record
    }

    private func methodCode(_ method: Method) -> UInt16 {
        switch method {
        case .stored: return 0
        case .deflate: return 8
        case .unsupported: return 14
        }
    }

    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = max(data.count * 2, 1_024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    static func uint32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    static func uint64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}
