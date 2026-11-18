//
//  PluginRowSpill.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProWireIO

// The disk every spill in this plugin draws from: half of what the volume has for important data, counting what the
// spools already hold, so concurrent runs leave room for the file an export writes. Read again at most every 10 s.
final class SpoolBudget: @unchecked Sendable {
    static let shared = SpoolBudget(limit: nil)

    private let fixedLimit: Int?
    private let lock = NSLock()
    private var inUse = 0
    private var limit = 0
    private var checkedAt: ContinuousClock.Instant?

    init(limit: Int?) {
        fixedLimit = limit
    }

    var bytesInUse: Int {
        lock.withLock { inUse }
    }

    func admits(_ bytes: Int) -> Bool {
        if let fixedLimit {
            return lock.withLock { inUse + bytes <= fixedLimit }
        }
        let now = ContinuousClock.now
        let (held, cached, stale) = lock.withLock { (inUse, limit, checkedAt.map { now - $0 > .seconds(10) } ?? true) }
        var current = cached
        if stale {
            let values = try? FileManager.default.temporaryDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            current = (Int(clamping: values?.volumeAvailableCapacityForImportantUsage ?? 0) + held) / 2
            lock.withLock {
                limit = current
                checkedAt = now
            }
        }
        return held + bytes <= current
    }

    func add(_ delta: Int) {
        lock.withLock { inUse += delta }
    }
}

// Takes a statement's rows without waiting for the reader, so the read, and its lock on a SQLite file, ends at the
// speed SQLite reads. What the stream's buffer refuses goes to a spool file and follows in order. Past the budget, or
// without a spool, the producer waits for the reader. One producer per spill.
final class PluginRowSpill: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginRowSpill")

    private let continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    private let budget: SpoolBudget
    private let makeSpool: @Sendable () throws -> SpoolFile

    private let lock = NSLock()
    private var spool: SpoolFile?
    // The spool's size as last counted against the budget.
    private var counted = 0
    private var spoolFailed = false
    // Batches in the spool that have not reached the stream yet.
    private var spilled = 0
    private var draining = false
    // The producer's end, held back while spilled batches are still on their way.
    private var outcome: Error??
    private var ended = false

    init(
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation,
        budget: SpoolBudget = .shared,
        makeSpool: @escaping @Sendable () throws -> SpoolFile = { try SpoolFile() }
    ) {
        self.continuation = continuation
        self.budget = budget
        self.makeSpool = makeSpool
    }

    // The header comes first, so the buffer is empty and takes it.
    func yield(_ header: PluginStreamHeader) {
        continuation.yield(.header(header))
    }

    // False once the reader has gone.
    @discardableResult
    func deliver(_ batch: [PluginRow]) -> Bool {
        lock.lock()
        if ended {
            lock.unlock()
            return false
        }
        if spilled == 0 {
            switch continuation.yield(.rows(batch)) {
            case .enqueued:
                lock.unlock()
                return true
            case .terminated:
                end()
                lock.unlock()
                return false
            case .dropped:
                break
            @unknown default:
                lock.unlock()
                return false
            }
        }
        let failed = spoolFailed
        let existing = spool
        lock.unlock()

        if !failed, spill(batch, into: existing) {
            return true
        }
        return deliverAtTheReadersPace(batch)
    }

    // False when the batch did not go to the spool: past the budget, or the spool failed.
    private func spill(_ batch: [PluginRow], into existing: SpoolFile?) -> Bool {
        let record = Self.encode(batch)
        guard budget.admits(record.count + 8) else { return false }
        do {
            let target = try existing ?? makeSpool()
            try target.append(record)
            return didSpill(into: target)
        } catch {
            Self.logger.error(
                "Rows no longer spill to a temporary file: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            lock.withLock {
                spoolFailed = true
                // With no drain left to notice, the space would stay taken until the stream ends.
                if !draining { releaseSpool() }
            }
            return false
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        guard spilled == 0, !draining else {
            outcome = .some(error)
            lock.unlock()
            return
        }
        end()
        lock.unlock()
        continuation.finish(throwing: error)
    }

    // The stream ended: nothing more goes in.
    func abandon() {
        lock.withLock { end() }
    }

    // Under the lock. The spool's space returns once the drain lets go of it too.
    private func end() {
        ended = true
        releaseSpool()
    }

    // Under the lock.
    private func releaseSpool() {
        spool = nil
        budget.add(-counted)
        counted = 0
    }

    // Under the lock.
    private func count(_ target: SpoolFile) {
        guard spool === target else { return }
        let size = target.byteCount
        budget.add(size - counted)
        counted = size
    }

    private func didSpill(into target: SpoolFile) -> Bool {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return false
        }
        spool = target
        spilled += 1
        count(target)
        let startsDrain = !draining
        draining = true
        lock.unlock()
        if startsDrain {
            Task { await self.drain(target) }
        }
        return true
    }

    private enum DrainStep {
        case stop
        case finish(Error?)
        case next
    }

    private func nextDrainStep() -> DrainStep {
        lock.withLock {
            if ended {
                draining = false
                return .stop
            }
            guard spilled == 0 else { return .next }
            draining = false
            // A failed spool takes no more batches, so its space goes back now rather than at the end.
            if spoolFailed { releaseSpool() }
            guard let outcome else { return .stop }
            end()
            return .finish(outcome)
        }
    }

    private func drain(_ target: SpoolFile) async {
        while true {
            switch nextDrainStep() {
            case .stop:
                return
            case .finish(let error):
                continuation.finish(throwing: error)
                return
            case .next:
                break
            }

            let batch: [PluginRow]
            do {
                guard let record = try target.next() else { throw SpoolFileError.readFailed(errno: EIO) }
                lock.withLock { count(target) }
                batch = try Self.decode(record)
            } catch {
                Self.logger.error(
                    "Spilled rows could not be read back: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
                lock.withLock {
                    end()
                    draining = false
                }
                continuation.finish(throwing: error is SpoolFileError ? error : SpoolFileError.readFailed(errno: EIO))
                return
            }
            guard await PluginRowStream.deliver(.rows(batch), to: continuation) else {
                lock.withLock {
                    end()
                    draining = false
                }
                return
            }
            lock.withLock { spilled -= 1 }
        }
    }

    // The batches already spilled reach the stream first; the spool is empty again by then.
    private func deliverAtTheReadersPace(_ batch: [PluginRow]) -> Bool {
        while true {
            let (waiting, gone) = lock.withLock { (spilled > 0, ended) }
            if gone { return false }
            if !waiting { break }
            usleep(2_000)
        }
        guard PluginRowStream.deliverBlocking(.rows(batch), to: continuation) else {
            lock.withLock { end() }
            return false
        }
        return true
    }

    // MARK: - Record

    private enum Tag: UInt8 {
        case null = 0
        case text = 1
        case bytes = 2
    }

    static func encode(_ batch: [PluginRow]) -> [UInt8] {
        var size = 4
        for row in batch {
            size += 4
            for cell in row {
                switch cell {
                case .null: size += 1
                case .text(let text): size += 5 + text.utf8.count
                case .bytes(let data): size += 5 + data.count
                }
            }
        }
        var record: [UInt8] = []
        record.reserveCapacity(size)
        appendLength(batch.count, to: &record)
        for row in batch {
            appendLength(row.count, to: &record)
            for cell in row {
                switch cell {
                case .null:
                    record.append(Tag.null.rawValue)
                case .text(var text):
                    record.append(Tag.text.rawValue)
                    text.withUTF8 { utf8 in
                        appendLength(utf8.count, to: &record)
                        record.append(contentsOf: utf8)
                    }
                case .bytes(let data):
                    record.append(Tag.bytes.rawValue)
                    appendLength(data.count, to: &record)
                    record.append(contentsOf: data)
                }
            }
        }
        return record
    }

    static func decode(_ record: [UInt8]) throws -> [PluginRow] {
        var reader = ByteReader(record)
        let declaredRows = try reader.u32()
        let rowCount = try reader.elementCount(declaredRows, minimumElementSize: 4)
        var batch: [PluginRow] = []
        batch.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            let declaredCells = try reader.u32()
            let cellCount = try reader.elementCount(declaredCells, minimumElementSize: 1)
            var row: PluginRow = []
            row.reserveCapacity(cellCount)
            for _ in 0..<cellCount {
                switch Tag(rawValue: try reader.u8()) {
                case .null:
                    row.append(.null)
                case .text:
                    let start = try skipValue(&reader)
                    row.append(.text(String(decoding: record[start..<reader.offset], as: UTF8.self)))
                case .bytes:
                    let start = try skipValue(&reader)
                    row.append(.bytes(Data(record[start..<reader.offset])))
                case nil:
                    throw SpoolFileError.readFailed(errno: EIO)
                }
            }
            batch.append(row)
        }
        return batch
    }

    private static func skipValue(_ reader: inout ByteReader) throws -> Int {
        let length = try reader.u32()
        let start = reader.offset
        try reader.skip(length)
        return start
    }

    private static func appendLength(_ length: Int, to record: inout [UInt8]) {
        withUnsafeBytes(of: UInt32(length).bigEndian) { record.append(contentsOf: $0) }
    }
}
