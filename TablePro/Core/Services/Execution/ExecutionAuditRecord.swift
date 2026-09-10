//
//  ExecutionAuditRecord.swift
//  TablePro
//

import CryptoKit
import Foundation

/// One authorization decision, chained to the one before it.
///
/// Every caller that touches a database goes through `ExecutionGate.authorize`, including the AI
/// assistant and the MCP tools, so a record per decision is a complete account of what the app was
/// asked to do and what it allowed.
///
/// `previousHash` makes the sequence self-describing: recomputing the chain shows whether any record
/// was edited, reordered or removed. That is tamper *evident*, not tamper proof. Anyone who can
/// write the file can also rewrite every hash after the record they changed. It raises silent edits
/// into visible ones; it does not make them impossible. Only an append-only store the user does not
/// control would do that, and TablePro runs no server.
internal struct ExecutionAuditRecord: Codable, Equatable, Sendable {
    internal let sequence: Int
    internal let recordedAt: Date
    internal let connectionId: UUID
    internal let kind: String
    /// Which subsystem asked. The distinction between a person clicking Save, an MCP client and the
    /// AI assistant is the first thing anyone reading an audit trail wants, and it is the reason
    /// this log is worth keeping at all.
    internal let caller: String
    internal let outcome: Outcome
    internal let effectiveWrite: Bool
    /// A digest, never the statement. A query holds customer data, and an audit trail that stores it
    /// turns a compliance feature into a second copy of the database.
    internal let statementDigest: String?
    internal let previousHash: String
    internal let hash: String

    internal enum Outcome: String, Codable, Sendable {
        case authorized
        case denied
    }

    internal static let genesisHash = String(repeating: "0", count: 64)

    internal init(
        sequence: Int,
        recordedAt: Date,
        connectionId: UUID,
        kind: String,
        caller: String,
        outcome: Outcome,
        effectiveWrite: Bool,
        statementDigest: String?,
        previousHash: String
    ) {
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.connectionId = connectionId
        self.kind = kind
        self.caller = caller
        self.outcome = outcome
        self.effectiveWrite = effectiveWrite
        self.statementDigest = statementDigest
        self.previousHash = previousHash
        hash = Self.digest(
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

    /// Every field except `hash` itself feeds the digest, joined by a separator that cannot appear
    /// in any of them. Concatenating without one lets two different records collide.
    internal static func digest(
        sequence: Int,
        recordedAt: Date,
        connectionId: UUID,
        kind: String,
        caller: String,
        outcome: Outcome,
        effectiveWrite: Bool,
        statementDigest: String?,
        previousHash: String
    ) -> String {
        let fields = [
            String(sequence),
            String(recordedAt.timeIntervalSince1970),
            connectionId.uuidString,
            kind,
            caller,
            outcome.rawValue,
            String(effectiveWrite),
            statementDigest ?? "",
            previousHash,
        ]
        return sha256(fields.joined(separator: "\u{1F}"))
    }

    internal static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Recomputes the chain and reports the first record that does not agree with it.
    internal static func firstBrokenSequence(in records: [ExecutionAuditRecord]) -> Int? {
        var expectedPrevious = genesisHash
        for (index, record) in records.enumerated() {
            let expectedHash = digest(
                sequence: record.sequence,
                recordedAt: record.recordedAt,
                connectionId: record.connectionId,
                kind: record.kind,
                caller: record.caller,
                outcome: record.outcome,
                effectiveWrite: record.effectiveWrite,
                statementDigest: record.statementDigest,
                previousHash: record.previousHash
            )
            if record.previousHash != expectedPrevious
                || record.hash != expectedHash
                || record.sequence != index {
                return record.sequence
            }
            expectedPrevious = record.hash
        }
        return nil
    }
}
