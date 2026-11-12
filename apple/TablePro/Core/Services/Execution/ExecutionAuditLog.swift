//
//  ExecutionAuditLog.swift
//  TablePro
//

import Foundation
import os

internal protocol ExecutionAuditLogging: Sendable {
    func record(request: OperationRequest, decision: OperationDecision) async
    func entries() async -> [ExecutionAuditRecord]
    func verify() async -> ExecutionAuditVerification
}

internal enum ExecutionAuditVerification: Equatable, Sendable {
    case intact(count: Int)
    case broken(atSequence: Int)
}

// The file stays the array older builds read and rewrite, so records go in over its closing bracket.
internal actor ExecutionAuditLog: ExecutionAuditLogging {
    internal static let shared = ExecutionAuditLog()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExecutionAudit")
    private static let tailWindow: UInt64 = 65_536
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let comma = UInt8(ascii: ",")
    private static let maxRecordLength = 4_096

    // What the file holds: its last record's link, and where its closing bracket sits.
    internal struct ChainHead: Equatable, Sendable {
        let nextSequence: Int
        let lastHash: String
        let closingBracketOffset: UInt64
        let fileSize: UInt64
    }

    private enum Disk {
        case noRecords
        case chain(ChainHead)
        case unavailable
    }

    // A decision before it has a place in the chain; it is linked to the head read when it is written.
    private struct Draft: Sendable {
        let recordedAt: Date
        let connectionId: UUID
        let kind: String
        let caller: String
        let outcome: ExecutionAuditRecord.Outcome
        let effectiveWrite: Bool
        let statementDigest: String?

        func linked(sequence: Int, previousHash: String) -> ExecutionAuditRecord {
            ExecutionAuditRecord(
                sequence: sequence,
                recordedAt: recordedAt,
                connectionId: connectionId,
                kind: kind,
                caller: caller,
                outcome: outcome,
                effectiveWrite: effectiveWrite,
                statementDigest: statementDigest,
                previousHash: previousHash
            )
        }

        func isWritten(as record: ExecutionAuditRecord) -> Bool {
            record.recordedAt == recordedAt && record.connectionId == connectionId && record.kind == kind
                && record.caller == caller && record.outcome == outcome && record.effectiveWrite == effectiveWrite
                && record.statementDigest == statementDigest
        }
    }

    // Identifies the file this actor last wrote, so a file replaced or edited since is read again.
    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ info: stat) {
            inode = UInt64(info.st_ino)
            size = UInt64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private let fileURL: URL
    private let retryInterval: Duration
    private var head: ChainHead?
    private var stamp: FileStamp?
    // Decided but not on disk yet, oldest first.
    private var pending: [Draft] = []
    private var retryAfter: ContinuousClock.Instant?

    internal init(fileURL: URL = ExecutionAuditLog.defaultFileURL(), retryInterval: Duration = .seconds(5)) {
        self.fileURL = fileURL
        self.retryInterval = retryInterval
    }

    // Inside the storage environment, so a UI test appends to its own sandbox and never to the real chain.
    internal static func defaultFileURL() -> URL {
        let directory = AppStorageEnvironment.shared.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ExecutionAudit.json")
    }

    internal func record(request: OperationRequest, decision: OperationDecision) async {
        let outcome: ExecutionAuditRecord.Outcome
        let effectiveWrite: Bool
        switch decision {
        case .authorized(let receipt):
            outcome = .authorized
            effectiveWrite = receipt.effectiveWrite
        case .denied:
            outcome = .denied
            effectiveWrite = false
        }

        pending.append(Draft(
            recordedAt: Date(),
            connectionId: request.connectionId,
            kind: String(describing: request.kind),
            caller: Self.describe(request.caller),
            outcome: outcome,
            effectiveWrite: effectiveWrite,
            statementDigest: request.sql.map(ExecutionAuditRecord.sha256)
        ))
        // A failure keeps the decision in `pending`; a disk that stays full is not retried on every authorization.
        if let retryAfter, ContinuousClock.now < retryAfter { return }
        retryAfter = writePending() ? nil : ContinuousClock.now + retryInterval
    }

    // A label, not the payload: an MCP client's label and an AI session id are caller-supplied and can carry anything.
    private static func describe(_ caller: OperationCaller) -> String {
        switch caller {
        case .userInterface: "userInterface"
        case .mcpClient: "mcpClient"
        case .aiAssistant: "aiAssistant"
        case .appleScript: "appleScript"
        case .shortcuts: "shortcuts"
        case .importPipeline: "importPipeline"
        case .backgroundMaintenance: "backgroundMaintenance"
        }
    }

    internal func entries() -> [ExecutionAuditRecord] {
        (try? readAllRecords()) ?? []
    }

    internal func verify() -> ExecutionAuditVerification {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return .intact(count: 0)
        }
        guard let records = try? readAllRecords() else { return .broken(atSequence: 0) }
        if let broken = ExecutionAuditRecord.firstBrokenSequence(in: records) {
            return .broken(atSequence: broken)
        }
        return .intact(count: records.count)
    }

    private func readAllRecords() throws -> [ExecutionAuditRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([ExecutionAuditRecord].self, from: data)
    }

    // MARK: - Appending

    private func writePending() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return startChain()
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: fileURL)
        } catch {
            Self.logger.error("Execution audit log could not be opened: \(error.publicLogShape, privacy: .public)")
            return false
        }
        defer { try? handle.close() }

        switch disk(through: handle) {
        case .unavailable:
            return false
        case .noRecords:
            return startChain()
        case .chain(let current):
            return append(after: current, through: handle)
        }
    }

    private func linkPending(after current: ChainHead?) -> [ExecutionAuditRecord] {
        var sequence = current?.nextSequence ?? 0
        var previousHash = current?.lastHash ?? ExecutionAuditRecord.genesisHash
        return pending.map { draft in
            let record = draft.linked(sequence: sequence, previousHash: previousHash)
            sequence += 1
            previousHash = record.hash
            return record
        }
    }

    private func disk(through handle: FileHandle) -> Disk {
        do {
            let current = try Self.stamp(of: handle)
            guard current.size > 0 else { return .noRecords }
            if let head, current == stamp {
                return .chain(head)
            }
            stamp = nil
            head = nil
            let read: (head: ChainHead, last: ExecutionAuditRecord?)
            if let found = try Self.readHead(from: handle, fileSize: current.size) {
                read = found
            } else if let repaired = try repairTail(of: handle, fileSize: current.size) {
                read = repaired
            } else {
                return setAsideUnreadableLog() ? .noRecords : .unavailable
            }
            dropWritten(upTo: read.last)
            return .chain(read.head)
        } catch {
            Self.logger.error("Execution audit log could not be read: \(error.publicLogShape, privacy: .public)")
            return .unavailable
        }
    }

    // An append that failed after its bytes landed must not write its records a second time.
    private func dropWritten(upTo last: ExecutionAuditRecord?) {
        guard let last, let index = pending.lastIndex(where: { $0.isWritten(as: last) }) else { return }
        pending.removeFirst(index + 1)
    }

    private func append(after current: ChainHead, through handle: FileHandle) -> Bool {
        guard !pending.isEmpty else { return true }
        let records = linkPending(after: current)
        guard let encoded = Self.encode(records), let last = records.last else { return false }
        var tail = Data()
        if current.nextSequence > 0 {
            tail.append(Self.comma)
        }
        tail.append(encoded)
        tail.append(Self.closeBracket)

        do {
            try handle.seek(toOffset: current.closingBracketOffset)
            try handle.write(contentsOf: tail)
            let newSize = current.closingBracketOffset + UInt64(tail.count)
            if newSize < current.fileSize {
                try handle.truncate(atOffset: newSize)
            }
            pending = []
            head = ChainHead(
                nextSequence: last.sequence + 1,
                lastHash: last.hash,
                closingBracketOffset: newSize - 1,
                fileSize: newSize
            )
            stamp = try? Self.stamp(of: handle)
            return true
        } catch {
            head = nil
            stamp = nil
            Self.restoreClosingBracket(of: handle, at: current.closingBracketOffset)
            Self.logger.error("Execution audit log could not be appended to: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    // Puts the array back as it was, so neither this build nor an older one finds an unterminated file.
    private static func restoreClosingBracket(of handle: FileHandle, at offset: UInt64) {
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([closeBracket]))
            try handle.truncate(atOffset: offset + 1)
        } catch {
            logger.error("Execution audit log could not be restored after a failed append")
        }
    }

    private func startChain() -> Bool {
        head = nil
        stamp = nil
        guard !pending.isEmpty else { return true }
        let records = linkPending(after: nil)
        guard let encoded = Self.encode(records), let last = records.last else { return false }
        var data = Data([Self.openBracket])
        data.append(encoded)
        data.append(Self.closeBracket)
        do {
            try data.write(to: fileURL, options: .atomic)
            pending = []
            head = ChainHead(
                nextSequence: last.sequence + 1,
                lastHash: last.hash,
                closingBracketOffset: UInt64(data.count - 1),
                fileSize: UInt64(data.count)
            )
            stamp = try? Self.stamp(atPath: fileURL.path(percentEncoded: false))
            return true
        } catch {
            Self.logger.error("Execution audit log could not be written: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    // A file cut short by a crash keeps the records before the cut; a copy of it as found goes aside first.
    private func repairTail(of handle: FileHandle, fileSize: UInt64) throws -> (head: ChainHead, last: ExecutionAuditRecord?)? {
        let start = fileSize > Self.tailWindow ? fileSize - Self.tailWindow : 0
        try handle.seek(toOffset: start)
        let bytes = [UInt8](try handle.read(upToCount: Int(fileSize - start)) ?? Data())
        guard let last = Self.lastRecord(in: bytes, endingAtOrBefore: bytes.count - 1) else { return nil }

        let destination = LocalSQLiteStoreOpener.setAsideURL(for: fileURL, at: Date())
        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } catch {
            Self.logger.error("Execution audit log could not be copied before its repair: \(error.publicLogShape, privacy: .public)")
            return nil
        }

        let closingOffset = start + UInt64(last.end) + 1
        try handle.seek(toOffset: closingOffset)
        try handle.write(contentsOf: Data([Self.closeBracket]))
        try handle.truncate(atOffset: closingOffset + 1)
        Self.logger.fault("Execution audit log ended mid-record; repaired after its last whole record, original kept aside")
        let head = ChainHead(
            nextSequence: last.record.sequence + 1,
            lastHash: last.record.hash,
            closingBracketOffset: closingOffset,
            fileSize: closingOffset + 1
        )
        return (head, last.record)
    }

    // The unreadable file is evidence: it is kept under a free name, and nothing is written while it cannot be moved.
    private func setAsideUnreadableLog() -> Bool {
        let destination = LocalSQLiteStoreOpener.setAsideURL(for: fileURL, at: Date())
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            Self.logger.fault("Execution audit log was unreadable and was set aside; a new chain starts")
            return true
        } catch {
            Self.logger.fault("Unreadable execution audit log could not be set aside: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    private static func encode(_ records: [ExecutionAuditRecord]) -> Data? {
        let encoder = JSONEncoder()
        var joined = Data()
        do {
            for (index, record) in records.enumerated() {
                if index > 0 {
                    joined.append(comma)
                }
                joined.append(try encoder.encode(record))
            }
            return joined
        } catch {
            logger.error("Execution audit record could not be encoded: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reading the tail

    private static func stamp(of handle: FileHandle) throws -> FileStamp {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStamp(info)
    }

    private static func stamp(atPath path: String) throws -> FileStamp {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStamp(info)
    }

    private static func readHead(
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> (head: ChainHead, last: ExecutionAuditRecord?)? {
        let start = fileSize > tailWindow ? fileSize - tailWindow : 0
        try handle.seek(toOffset: start)
        let bytes = [UInt8](try handle.read(upToCount: Int(fileSize - start)) ?? Data())
        guard let head = chainHead(inTail: Data(bytes), startingAt: start, fileSize: fileSize) else { return nil }
        guard head.nextSequence > 0,
              let closing = lastNonWhitespaceIndex(in: bytes, before: bytes.count),
              let beforeClosing = lastNonWhitespaceIndex(in: bytes, before: closing)
        else { return (head, nil) }
        return (head, decodedRecord(in: bytes, endingAt: beforeClosing))
    }

    internal static func chainHead(inTail tail: Data, startingAt start: UInt64, fileSize: UInt64) -> ChainHead? {
        let bytes = [UInt8](tail)
        guard let closing = lastNonWhitespaceIndex(in: bytes, before: bytes.count),
              bytes[closing] == closeBracket,
              let beforeClosing = lastNonWhitespaceIndex(in: bytes, before: closing)
        else { return nil }

        let closingOffset = start + UInt64(closing)
        if bytes[beforeClosing] == openBracket {
            guard start == 0, lastNonWhitespaceIndex(in: bytes, before: beforeClosing) == nil else { return nil }
            return ChainHead(
                nextSequence: 0,
                lastHash: ExecutionAuditRecord.genesisHash,
                closingBracketOffset: closingOffset,
                fileSize: fileSize
            )
        }
        guard let record = decodedRecord(in: bytes, endingAt: beforeClosing) else { return nil }
        return ChainHead(
            nextSequence: record.sequence + 1,
            lastHash: record.hash,
            closingBracketOffset: closingOffset,
            fileSize: fileSize
        )
    }

    internal static func lastRecord(
        in bytes: [UInt8],
        endingAtOrBefore limit: Int
    ) -> (record: ExecutionAuditRecord, end: Int)? {
        var end = limit
        while end > 0 {
            if let record = decodedRecord(in: bytes, endingAt: end) {
                return (record, end)
            }
            end -= 1
        }
        return nil
    }

    // Records are flat and short, so one starts at the nearest `{` before its `}`, right after a `,` or the `[`.
    private static func decodedRecord(in bytes: [UInt8], endingAt end: Int) -> ExecutionAuditRecord? {
        guard end > 0, end < bytes.count, bytes[end] == closeBrace,
              let start = bytes[max(0, end - maxRecordLength) ..< end].lastIndex(of: openBrace),
              let separator = lastNonWhitespaceIndex(in: bytes, before: start),
              bytes[separator] == comma || bytes[separator] == openBracket
        else { return nil }
        return try? JSONDecoder().decode(ExecutionAuditRecord.self, from: Data(bytes[start ... end]))
    }

    private static func lastNonWhitespaceIndex(in bytes: [UInt8], before end: Int) -> Int? {
        var index = end - 1
        while index >= 0 {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index -= 1
            default:
                return index
            }
        }
        return nil
    }
}
