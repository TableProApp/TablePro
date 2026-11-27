#if canImport(Darwin)
import Darwin
import Foundation

public enum SpoolFileError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case cannotCreate(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)

    public var description: String {
        switch self {
        case .cannotCreate(let code): return "could not create a temporary file: \(String(cString: strerror(code)))"
        case .writeFailed(let code): return "could not write a temporary file: \(String(cString: strerror(code)))"
        case .readFailed(let code): return "could not read a temporary file: \(String(cString: strerror(code)))"
        }
    }

    // The system's own localized text for the errno.
    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let code), .writeFailed(let code), .readFailed(let code):
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }
}

// Records read back in append order, in a file mkostemp makes 0600 and that is unlinked at once, so nothing is left
// after a crash or quit. The descriptor closes only in deinit, so no read meets a reused number.
public final class SpoolFile: @unchecked Sendable {
    private static let headerSize = 8
    private static let readChunk = 64 * 1_024

    private let descriptor: Int32
    // One thread appends while another reads; the lock covers what the two share and the truncate, not reads or writes.
    private let lock = NSLock()
    private var written = 0
    private var appending = false
    private var readBuffer: [UInt8] = []
    private var readStart = 0
    private var fileReadOffset = 0

    public init(directory: URL = FileManager.default.temporaryDirectory, prefix: String = "TablePro-spool") throws {
        var template = Array(directory.appending(path: "\(prefix)-XXXXXX").path(percentEncoded: false).utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map { mkostemp($0, O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw SpoolFileError.cannotCreate(errno: errno) }
        guard template.withUnsafeBufferPointer({ unlink($0.baseAddress) }) == 0 else {
            let code = errno
            close(descriptor)
            throw SpoolFileError.cannotCreate(errno: code)
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    // The bytes on disk, length prefixes included. Zero again once the reader has taken every record.
    public var byteCount: Int {
        lock.withLock { written }
    }

    // A failed append leaves every earlier record readable and adds nothing.
    public func append(_ record: some ContiguousBytes) throws {
        let offset = lock.withLock {
            appending = true
            return written
        }
        do {
            let end = try record.withUnsafeBytes { body in
                var header = UInt64(body.count).bigEndian
                if body.count <= Self.readChunk {
                    var bytes = withUnsafeBytes(of: &header) { [UInt8]($0) }
                    bytes.append(contentsOf: body)
                    try bytes.withUnsafeBytes { try write($0, at: offset) }
                } else {
                    try withUnsafeBytes(of: &header) { try write($0, at: offset) }
                    try write(body, at: offset + Self.headerSize)
                }
                return offset + Self.headerSize + body.count
            }
            lock.withLock {
                written = end
                appending = false
            }
        } catch {
            lock.withLock { appending = false }
            throw error
        }
    }

    // The next record, or nil once every record appended so far has been read.
    public func next() throws -> [UInt8]? {
        let end = lock.withLock { written }
        let position = fileReadOffset - (readBuffer.count - readStart)
        guard position < end else { return nil }
        let header = try take(Self.headerSize, end: end)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard (0...(end - position - Self.headerSize)).contains(length) else {
            throw SpoolFileError.readFailed(errno: EIO)
        }
        let record = try take(length, end: end)
        if fileReadOffset - (readBuffer.count - readStart) == end {
            emptyFileIfIdle(at: end)
        }
        return record
    }

    // Only while no append runs and none has landed since `end`, so the writer's next offset is the new start.
    private func emptyFileIfIdle(at end: Int) {
        lock.withLock {
            guard !appending, written == end, ftruncate(descriptor, 0) == 0 else { return }
            written = 0
            fileReadOffset = 0
            readStart = 0
            readBuffer.removeAll()
        }
    }

    private func take(_ count: Int, end: Int) throws -> [UInt8] {
        let buffered = readBuffer.count - readStart
        if buffered >= count {
            defer { readStart += count }
            return Array(readBuffer[readStart..<(readStart + count)])
        }
        if count - buffered > Self.readChunk {
            var record = Array(readBuffer[readStart...])
            readBuffer.removeAll(keepingCapacity: true)
            readStart = 0
            record.append(contentsOf: repeatElement(0, count: count - buffered))
            try read(into: &record, from: buffered, at: fileReadOffset)
            fileReadOffset += count - buffered
            return record
        }
        readBuffer.removeSubrange(0..<readStart)
        readStart = 0
        let filled = readBuffer.count
        readBuffer.append(contentsOf: repeatElement(0, count: min(Self.readChunk, end - fileReadOffset)))
        do {
            try read(into: &readBuffer, from: filled, at: fileReadOffset)
        } catch {
            readBuffer.removeSubrange(filled...)
            throw error
        }
        fileReadOffset += readBuffer.count - filled
        defer { readStart += count }
        return Array(readBuffer[readStart..<(readStart + count)])
    }

    // Fills `buffer` from `start` to its end.
    private func read(into buffer: inout [UInt8], from start: Int, at offset: Int) throws {
        let count = buffer.count - start
        var done = 0
        while done < count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(descriptor, base + start + done, count - done, off_t(offset + done))
            }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw SpoolFileError.readFailed(errno: read == 0 ? EIO : errno) }
            done += read
        }
    }

    private func write(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
        guard let base = bytes.baseAddress else { return }
        var done = 0
        while done < bytes.count {
            let wrote = pwrite(descriptor, base + done, bytes.count - done, off_t(offset + done))
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw SpoolFileError.writeFailed(errno: wrote == 0 ? EIO : errno) }
            done += wrote
        }
    }
}
#endif
