import Foundation

public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int

        public init(path: String, compressionMethod: UInt16, compressedSize: Int, uncompressedSize: Int, localHeaderOffset: Int) {
            self.path = path
            self.compressionMethod = compressionMethod
            self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize
            self.localHeaderOffset = localHeaderOffset
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case notAZipArchive
        case entryNotFound(String)
        case unsupportedCompression(UInt16)
        case corruptEntry(String)
        case entryTooLarge(String)

        public var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                return String(localized: "That file is not a valid XLSX workbook.")
            case .entryNotFound(let name):
                return String(format: String(localized: "The workbook is missing %@."), name)
            case .unsupportedCompression(let method):
                return String(
                    format: String(localized: "The workbook uses compression method %d, which TablePro cannot read."),
                    Int(method)
                )
            case .corruptEntry(let name):
                return String(format: String(localized: "Could not read %@ from the workbook."), name)
            case .entryTooLarge(let name):
                return String(format: String(localized: "%@ in the workbook expands to far more data than it holds, so it was not read."), name)
            }
        }
    }

    public static let storedMethod: UInt16 = 0
    public static let deflateMethod: UInt16 = 8
    public static let bufferedEntryLimit = 256 << 20

    public let bytes: Data
    public let entries: [String: Entry]

    public init(bytes: Data) throws {
        self.bytes = bytes
        self.entries = try bytes.withUnsafeBytes { raw in
            try ZipCentralDirectory.entries(in: raw.bindMemory(to: UInt8.self))
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public var paths: [String] {
        entries.keys.sorted()
    }

    public func entry(named path: String) -> Entry? {
        entries[path]
    }

    public func entry(matching path: String) -> Entry? {
        if let exact = entries[path] {
            return exact
        }
        let folded = path.lowercased()
        return entries.first { $0.key.lowercased() == folded }?.value
    }

    public func data(named path: String) throws -> Data {
        guard let entry = entries[path] else { throw Failure.entryNotFound(path) }
        return try data(for: entry)
    }

    public func data(
        for entry: Entry,
        limit: Int = bufferedEntryLimit,
        policy: ZipExpansionPolicy = .standard
    ) throws -> Data {
        guard entry.uncompressedSize <= limit else { throw Failure.entryTooLarge(entry.path) }
        return try withReader(for: entry, policy: policy) { reader in
            var output = Data()
            output.reserveCapacity(max(entry.uncompressedSize, 0))
            let chunk = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256 * 1_024)
            defer { chunk.deallocate() }
            while true {
                let produced = try reader.read(into: chunk)
                guard produced > 0, let base = chunk.baseAddress else { return output }
                output.append(base, count: produced)
            }
        }
    }

    public func withReader<Result>(
        for entry: Entry,
        policy: ZipExpansionPolicy = .standard,
        _ body: (inout ZipEntryReader) throws -> Result
    ) throws -> Result {
        try bytes.withUnsafeBytes { raw in
            let archive = raw.bindMemory(to: UInt8.self)
            let payload = try ZipCentralDirectory.payload(of: entry, in: archive)
            var reader = try ZipEntryReader(entry: entry, payload: payload, policy: policy)
            return try body(&reader)
        }
    }
}

enum ZipCentralDirectory {
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let endOfDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndOfDirectorySignature: UInt32 = 0x0606_4B50
    private static let zip64ExtraFieldID: UInt16 = 0x0001
    private static let saturated32: UInt32 = 0xFFFF_FFFF
    private static let centralHeaderLength = 46
    private static let localHeaderLength = 30
    private static let endOfDirectoryLength = 22

    static func entries(in bytes: UnsafeBufferPointer<UInt8>) throws -> [String: ZipArchive.Entry] {
        guard let directoryStart = directoryOffset(in: bytes) else {
            throw ZipArchive.Failure.notAZipArchive
        }
        var entries: [String: ZipArchive.Entry] = [:]
        var cursor = directoryStart
        while fits(cursor, centralHeaderLength, in: bytes), readUInt32(bytes, cursor) == centralHeaderSignature {
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let nameStart = cursor + centralHeaderLength
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength <= bytes.count else { break }
            let name = TabularTextCodec.string(from: UnsafeBufferPointer(rebasing: bytes[nameStart..<extraStart]), encoding: .utf8)
            var sizes = EntrySizes(
                compressed: UInt64(readUInt32(bytes, cursor + 20)),
                uncompressed: UInt64(readUInt32(bytes, cursor + 24)),
                offset: UInt64(readUInt32(bytes, cursor + 42))
            )
            applyZip64Extra(bytes, range: extraStart..<(extraStart + extraLength), to: &sizes)
            entries[name] = ZipArchive.Entry(
                path: name,
                compressionMethod: readUInt16(bytes, cursor + 10),
                compressedSize: Int(clamping: sizes.compressed),
                uncompressedSize: Int(clamping: sizes.uncompressed),
                localHeaderOffset: Int(clamping: sizes.offset)
            )
            cursor = extraStart + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw ZipArchive.Failure.notAZipArchive }
        return entries
    }

    static func payload(of entry: ZipArchive.Entry, in bytes: UnsafeBufferPointer<UInt8>) throws -> UnsafeBufferPointer<UInt8> {
        let headerStart = entry.localHeaderOffset
        guard fits(headerStart, localHeaderLength, in: bytes), readUInt32(bytes, headerStart) == localHeaderSignature else {
            throw ZipArchive.Failure.corruptEntry(entry.path)
        }
        let nameLength = Int(readUInt16(bytes, headerStart + 26))
        let extraLength = Int(readUInt16(bytes, headerStart + 28))
        let payloadStart = headerStart + localHeaderLength + nameLength + extraLength
        guard fits(payloadStart, entry.compressedSize, in: bytes) else {
            throw ZipArchive.Failure.corruptEntry(entry.path)
        }
        return UnsafeBufferPointer(rebasing: bytes[payloadStart..<(payloadStart + entry.compressedSize)])
    }

    private struct EntrySizes {
        var compressed: UInt64
        var uncompressed: UInt64
        var offset: UInt64
    }

    private static func applyZip64Extra(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, to sizes: inout EntrySizes) {
        let needsUncompressed = sizes.uncompressed == UInt64(saturated32)
        let needsCompressed = sizes.compressed == UInt64(saturated32)
        let needsOffset = sizes.offset == UInt64(saturated32)
        guard needsUncompressed || needsCompressed || needsOffset else { return }
        var cursor = range.lowerBound
        while cursor + 4 <= range.upperBound {
            let fieldID = readUInt16(bytes, cursor)
            let fieldLength = Int(readUInt16(bytes, cursor + 2))
            let dataStart = cursor + 4
            let dataEnd = min(dataStart + fieldLength, range.upperBound)
            guard fieldID == zip64ExtraFieldID else {
                cursor = dataStart + fieldLength
                continue
            }
            var field = dataStart
            if needsUncompressed, field + 8 <= dataEnd {
                sizes.uncompressed = readUInt64(bytes, field)
                field += 8
            }
            if needsCompressed, field + 8 <= dataEnd {
                sizes.compressed = readUInt64(bytes, field)
                field += 8
            }
            if needsOffset, field + 8 <= dataEnd {
                sizes.offset = readUInt64(bytes, field)
            }
            return
        }
    }

    private static func directoryOffset(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard bytes.count >= endOfDirectoryLength else { return nil }
        let searchLimit = min(bytes.count, 64 * 1_024 + endOfDirectoryLength)
        let lowest = bytes.count - searchLimit
        var cursor = bytes.count - endOfDirectoryLength
        while cursor >= lowest {
            if readUInt32(bytes, cursor) == endOfDirectorySignature {
                let offset = readUInt32(bytes, cursor + 16)
                guard offset == saturated32 else { return Int(offset) }
                return zip64DirectoryOffset(in: bytes, endOfDirectory: cursor) ?? Int(offset)
            }
            cursor -= 1
        }
        return nil
    }

    private static func zip64DirectoryOffset(in bytes: UnsafeBufferPointer<UInt8>, endOfDirectory: Int) -> Int? {
        let locator = endOfDirectory - 20
        guard locator >= 0, readUInt32(bytes, locator) == zip64LocatorSignature else { return nil }
        let recordOffset = Int(clamping: readUInt64(bytes, locator + 8))
        guard fits(recordOffset, 56, in: bytes), readUInt32(bytes, recordOffset) == zip64EndOfDirectorySignature else {
            return nil
        }
        return Int(clamping: readUInt64(bytes, recordOffset + 48))
    }

    static func fits(_ start: Int, _ length: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        start >= 0 && length >= 0 && start <= bytes.count && length <= bytes.count - start
    }

    static func readUInt16(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt16 {
        guard fits(offset, 2, in: bytes) else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        guard fits(offset, 4, in: bytes) else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func readUInt64(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt64 {
        guard fits(offset, 8, in: bytes) else { return 0 }
        return UInt64(readUInt32(bytes, offset)) | (UInt64(readUInt32(bytes, offset + 4)) << 32)
    }
}
