//
//  JSONFileStore.swift
//  TablePro
//

import Foundation

// One JSON-encoded value in one file. Files with an integrity tag use `IntegrityStampedFileStore`.
internal struct JSONFileStore<Value>: Sendable {
    internal let url: URL
    internal let coding: StoreCoding
    internal let writingOptions: Data.WritingOptions

    internal init(url: URL, coding: StoreCoding = .plain, writingOptions: Data.WritingOptions = .atomic) {
        self.url = url
        self.coding = coding
        self.writingOptions = writingOptions
    }

    private var name: String { url.lastPathComponent }

    internal var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    internal func read() -> StoreRead<Value> where Value: Decodable {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            StoreLog.unreadable(name, error)
            return .unreadable(error)
        }
        do {
            return .value(try coding.decode(Value.self, from: data))
        } catch {
            StoreLog.unreadable(name, error)
            return .unreadable(error)
        }
    }

    internal func write(_ value: Value) throws where Value: Encodable {
        let data: Data
        do {
            data = try coding.encode(value)
        } catch {
            StoreLog.unwritable(name, error)
            throw error
        }
        try write(encoded: data)
    }

    // For a caller that already encoded the value with `coding`, such as one checking its size first.
    internal func write(encoded data: Data) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: writingOptions)
        } catch {
            StoreLog.unwritable(name, error)
            throw error
        }
    }

    internal func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            StoreLog.unwritable(name, error)
            throw error
        }
    }
}
