//
//  NativeDumpBatch.swift
//  TablePro
//

import Foundation
import Observation
import os

/// One database's share of a backup.
struct NativeDumpBatchItem: Sendable, Equatable {
    let database: String
    let scope: NativeDumpScope
    let destination: URL
}

/// How one item ended.
struct NativeDumpBatchOutcome: Sendable, Equatable {
    enum Result: Sendable, Equatable {
        case succeeded(bytes: Int64)
        case failed(message: String)
        case cancelled
    }

    let database: String
    let destination: URL
    let result: Result

    var succeeded: Bool {
        guard case .succeeded = result else { return false }
        return true
    }
}

/// The slice of `NativeDumpService` a batch drives. Injected the same way `NativeDumpRunner` is,
/// so the sequencing, the per-item outcomes and the cancel path can be exercised without a live
/// connection or a subprocess.
@MainActor
protocol NativeDumpRunning: AnyObject {
    func stateUpdates() -> AsyncStream<NativeDumpState>
    func start(
        connection: DatabaseConnection,
        database: String,
        fileURL: URL,
        scope: NativeDumpScope,
        formatId: String?,
        totalBytesEstimate: Int64?
    ) async throws
    func cancel()
}

extension NativeDumpService: NativeDumpRunning {}

struct NativeDumpBatchState: Equatable {
    var isRunning = false
    var isCancelling = false
    var currentDatabase = ""
    var currentIndex = 0
    var total = 0
    var bytesProcessed: Int64 = 0
    var totalBytes: Int64?
    var outcomes: [NativeDumpBatchOutcome] = []

    var isFinished: Bool {
        !isRunning && total > 0 && outcomes.count == total
    }
}

/// Runs several databases through `NativeDumpService`, one after another.
///
/// Sequential rather than concurrent: every engine here either spawns a client that opens its own
/// connection or runs statements on the one session driver, and three of those at once would fight
/// for the same handle while making the progress bar meaningless.
///
/// It keeps going after an item fails, where `TableTransferService` and `ExportService` both abort
/// on the first error. Those two write one artifact, so a failure part way through has already
/// spoiled it; a backup of three databases writes three independent files, and losing the third
/// because the second was unreadable helps nobody. Every item's outcome is reported, so a partial
/// run never looks like a whole one.
@MainActor
@Observable
final class NativeDumpBatch {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "NativeDumpBatch")

    private(set) var state = NativeDumpBatchState()

    @ObservationIgnored private let makeService: @MainActor () -> any NativeDumpRunning
    @ObservationIgnored private let estimateSize: @MainActor (DatabaseConnection, String) async -> Int64?
    @ObservationIgnored private var current: (any NativeDumpRunning)?
    @ObservationIgnored private var cancelled = false

    init(
        makeService: @escaping @MainActor () -> any NativeDumpRunning = { NativeDumpService(kind: .backup) },
        estimateSize: @escaping @MainActor (DatabaseConnection, String) async -> Int64? = { connection, database in
            await NativeDumpService.estimatedDatabaseSize(connection: connection, database: database)
        }
    ) {
        self.makeService = makeService
        self.estimateSize = estimateSize
    }

    func cancel() {
        guard state.isRunning, !state.isCancelling else { return }
        cancelled = true
        state.isCancelling = true
        current?.cancel()
    }

    func run(
        connection: DatabaseConnection,
        items: [NativeDumpBatchItem],
        formatId: String?
    ) async {
        guard !items.isEmpty, !state.isRunning else { return }
        cancelled = false
        state = NativeDumpBatchState(isRunning: true, total: items.count)
        defer {
            state.isRunning = false
            state.isCancelling = false
            current = nil
        }

        let producesDirectory = NativeDumpRegistry
            .descriptor(for: connection.type, formatId: formatId)?
            .archiveFormat.producesDirectory ?? false

        for (index, item) in items.enumerated() {
            guard !cancelled else {
                appendRemainingAsCancelled(from: index, items: items)
                return
            }
            state.currentDatabase = item.database
            state.currentIndex = index + 1
            state.bytesProcessed = 0
            state.totalBytes = nil
            await runOne(
                connection: connection,
                item: item,
                formatId: formatId,
                producesDirectory: producesDirectory
            )
        }
    }

    private func appendRemainingAsCancelled(from index: Int, items: [NativeDumpBatchItem]) {
        for item in items[index...] {
            state.outcomes.append(
                NativeDumpBatchOutcome(
                    database: item.database, destination: item.destination, result: .cancelled
                )
            )
        }
    }

    private func runOne(
        connection: DatabaseConnection,
        item: NativeDumpBatchItem,
        formatId: String?,
        producesDirectory: Bool
    ) async {
        do {
            try NativeDumpDestination.prepare(item.destination, producesDirectory: producesDirectory)
        } catch {
            record(item, .failed(message: error.localizedDescription))
            return
        }

        let service = makeService()
        current = service
        let updates = service.stateUpdates()

        let estimate = await estimateSize(connection, item.database)
        guard !cancelled else {
            record(item, .cancelled)
            return
        }
        state.totalBytes = estimate

        do {
            try await service.start(
                connection: connection,
                database: item.database,
                fileURL: item.destination,
                scope: item.scope,
                formatId: formatId,
                totalBytesEstimate: estimate
            )
        } catch {
            record(item, .failed(message: error.localizedDescription))
            return
        }

        for await update in updates {
            switch update {
            case .running(_, _, let bytes, let total):
                state.bytesProcessed = bytes
                state.totalBytes = total ?? state.totalBytes
            case .finished(_, _, let bytes):
                record(item, .succeeded(bytes: bytes))
                return
            case .failed(let message, _):
                Self.logger.error("batch item failed db=\(item.database, privacy: .public)")
                record(item, .failed(message: message))
                return
            case .cancelled:
                record(item, .cancelled)
                return
            case .idle, .cancelling:
                continue
            }
        }
    }

    private func record(_ item: NativeDumpBatchItem, _ result: NativeDumpBatchOutcome.Result) {
        state.outcomes.append(
            NativeDumpBatchOutcome(
                database: item.database, destination: item.destination, result: result
            )
        )
        current = nil
    }
}
