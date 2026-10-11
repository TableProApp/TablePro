//
//  JSONLineReader.swift
//  JSONImportPlugin
//

import Foundation

/// Reads a JSON Lines file one line at a time, holding one chunk and the line in progress.
///
/// A line ends at a 0x0A byte and nowhere else, and its bytes go to the JSON parser undecoded.
/// Decoding a fixed-size prefix as text failed whenever the prefix ended inside a multi-byte
/// character. `URL.lines` also ends a line at U+2028, U+2029 and U+0085, which JSON allows
/// unescaped inside a string, and it reads through `FileHandle.AsyncBytes`, whose one
/// process-wide queue a reader waiting on a quiet pipe elsewhere in the app holds.
///
/// A stop is checked before every chunk rather than between lines, because one line can run to
/// the end of a file that holds no newline at all.
struct JSONLineReader {
    static let defaultChunkSize = 1 << 20

    private let handle: FileHandle
    private let chunkSize: Int
    private let checkCancellation: () throws -> Void
    private var buffer = Data()
    private var lineStart = 0
    private var searchedUpTo = 0
    private var reachedEnd = false

    private(set) var lineNumber = 0

    init(
        url: URL,
        chunkSize: Int = Self.defaultChunkSize,
        checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = max(1, chunkSize)
        self.checkCancellation = checkCancellation
    }

    mutating func next() throws -> Data? {
        while true {
            if let newline = firstNewline() {
                let line = buffer[lineStart..<newline]
                lineStart = newline + 1
                searchedUpTo = lineStart
                lineNumber += 1
                return line
            }
            searchedUpTo = buffer.count
            if reachedEnd {
                guard lineStart < buffer.count else { return nil }
                let line = buffer[lineStart...]
                lineStart = buffer.count
                lineNumber += 1
                return line
            }
            try refill()
        }
    }

    func close() {
        try? handle.close()
    }

    private func firstNewline() -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            guard searchedUpTo < raw.count, let base = raw.baseAddress else { return nil }
            guard let found = memchr(base + searchedUpTo, 0x0A, raw.count - searchedUpTo) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }

    private mutating func refill() throws {
        try checkCancellation()
        if lineStart > 0 {
            buffer.removeSubrange(0..<lineStart)
            searchedUpTo -= lineStart
            lineStart = 0
        }
        let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) } ?? Data()
        guard !chunk.isEmpty else {
            reachedEnd = true
            return
        }
        buffer.append(chunk)
    }
}
