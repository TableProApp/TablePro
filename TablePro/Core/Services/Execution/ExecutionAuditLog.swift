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

/// Append-only log of every authorization decision, written from inside `ExecutionGate`.
///
/// An actor rather than a lock: the gate is called from many tasks, and the sequence number and the
/// previous hash have to be read and advanced together or two concurrent decisions produce two
/// records claiming the same position.
internal actor ExecutionAuditLog: ExecutionAuditLogging {
    internal static let shared = ExecutionAuditLog()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExecutionAudit")

    private let fileURL: URL
    private var records: [ExecutionAuditRecord] = []
    private var loaded = false

    internal init(fileURL: URL = ExecutionAuditLog.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Resolved through `AppStorageEnvironment` like every other store, so a UI test appends to its
    /// own sandbox. The chain is hash linked, which makes a foreign entry indistinguishable from a
    /// real one rather than merely noise.
    internal static func defaultFileURL() -> URL {
        let directory = AppStorageEnvironment.shared.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ExecutionAudit.json")
    }

    internal func record(request: OperationRequest, decision: OperationDecision) async {
        load()

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

        let record = ExecutionAuditRecord(
            sequence: records.count,
            recordedAt: Date(),
            connectionId: request.connectionId,
            kind: String(describing: request.kind),
            caller: Self.describe(request.caller),
            outcome: outcome,
            effectiveWrite: effectiveWrite,
            statementDigest: request.sql.map(ExecutionAuditRecord.sha256),
            previousHash: records.last?.hash ?? ExecutionAuditRecord.genesisHash
        )
        records.append(record)
        persist()
    }

    /// A label, not the payload. An MCP client's label and an AI session id are caller-supplied and
    /// can carry anything, so only the channel is recorded.
    private static func describe(_ caller: OperationCaller) -> String {
        switch caller {
        case .userInterface: "userInterface"
        case .mcpClient: "mcpClient"
        case .aiAssistant: "aiAssistant"
        case .appleScript: "appleScript"
        case .importPipeline: "importPipeline"
        case .backgroundMaintenance: "backgroundMaintenance"
        }
    }

    internal func entries() -> [ExecutionAuditRecord] {
        load()
        return records
    }

    internal func verify() -> ExecutionAuditVerification {
        load()
        if let broken = ExecutionAuditRecord.firstBrokenSequence(in: records) {
            return .broken(atSequence: broken)
        }
        return .intact(count: records.count)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try JSONDecoder().decode([ExecutionAuditRecord].self, from: data)
        } catch {
            // A log that cannot be read is itself a finding, so it is reported rather than
            // silently replaced. Starting a fresh chain over it would destroy the evidence.
            Self.logger.error("Execution audit log could not be decoded: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Execution audit log could not be written: \(error.localizedDescription)")
        }
    }
}
