//
//  SyncApprovalsModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI

// The core's approval queue (core ADR 0044, Fields a pull applies only with approval; 0054, Rules for both providers;
// 0066), so the review is tested over a fake engine.
nonisolated protocol SyncApprovalEngine: AnyObject, Sendable {
    func status() -> SyncStatusInfo
    func approvals() async throws -> [RecordApprovalInfo]
    func decideRecordApproval(record: SyncRecordRef, digest: String, approve: Bool) async throws
}

extension SyncService: SyncApprovalEngine {}

internal struct SyncApprovalFailure: Equatable {
    // Nil when Approve All stopped on it.
    let record: SyncRecordRef?
    let message: String
}

// What pulled changes wait for the person on this Mac, whichever provider pulled them. The count is the engine's own,
// so the status line and the Welcome window say the same; the list is read only while something waits.
@MainActor
internal final class SyncApprovalsModel: ObservableObject {
    static let shared = SyncApprovalsModel()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SyncApprovals")

    @Published private(set) var waiting = 0
    @Published private(set) var records: [RecordApprovalInfo] = []
    // The list matches the count only after a read that succeeded; until then the sheet says it is loading, or that the
    // read failed, and never that nothing waits.
    @Published private(set) var hasRead = false
    @Published private(set) var readFailed = false
    // The records a decision is out for; every action waits while it is not empty.
    @Published private(set) var deciding: Set<SyncRecordRef> = []
    @Published private(set) var failure: SyncApprovalFailure?

    private let engine: @MainActor () -> (any SyncApprovalEngine)?
    private let changes: AnyPublisher<Void, Never>
    private let readCoreWrites: @MainActor () -> Void
    private var observer: AnyCancellable?
    // Each read and each decision takes the next one, so a read that began before a decision changes nothing after it.
    private var generation = 0

    init(
        engine: @escaping @MainActor () -> (any SyncApprovalEngine)? = {
            SyncEngineHost.shared.openedEngine(for: .off) as? any SyncApprovalEngine
        },
        changes: AnyPublisher<Void, Never> = SyncEngineHost.shared.approvalChanges,
        readCoreWrites: @escaping @MainActor () -> Void = { ConnectionStorage.shared.readCoreWrites() }
    ) {
        self.engine = engine
        self.changes = changes
        self.readCoreWrites = readCoreWrites
    }

    var isDeciding: Bool {
        !deciding.isEmpty
    }

    func start() {
        guard observer == nil else { return }
        observer = changes.sink { [weak self] in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // The count shows at once, before the list is read. A failed read keeps what is shown and says so; the next signal
    // or Try Again reads again.
    func refresh() async {
        generation += 1
        let started = generation
        guard let engine = engine() else {
            show(waiting: 0, records: [])
            return
        }
        let count = Int(engine.status().waitingApprovals)
        if waiting != count {
            waiting = count
        }
        guard count > 0 else {
            show(waiting: 0, records: [])
            return
        }
        if records.isEmpty, hasRead {
            hasRead = false
        }
        let read: [RecordApprovalInfo]
        do {
            read = try await engine.approvals()
        } catch {
            Self.logger.error("Reading the approvals failed: \(error.publicLogShape, privacy: .public)")
            if started == generation {
                readFailed = true
            }
            return
        }
        guard started == generation else { return }
        show(waiting: count, records: read)
    }

    // `record` is the copy the sheet showed, never one read since: its digest makes the core refuse a decision on values a
    // pull changed after that, and the new values show instead, so an approval never applies a value the person did not
    // see.
    func decide(_ record: RecordApprovalInfo, approve: Bool) async {
        guard deciding.isEmpty else { return }
        deciding = [record.record]
        defer { deciding = [] }
        failure = nil
        switch await send(record, approve: approve) {
        case .done:
            break
        case .changed:
            failure = SyncApprovalFailure(record: record.record, message: Self.changedAgainMessage)
        case .failed(let message):
            failure = SyncApprovalFailure(record: record.record, message: message)
        }
        await settle()
    }

    // The records as the sheet showed them, one at a time in that order. A record a pull changed meanwhile is left for
    // the person, and the others still go.
    func approveAll(_ listed: [RecordApprovalInfo]) async {
        guard deciding.isEmpty, !listed.isEmpty else { return }
        deciding = Set(listed.map(\.record))
        defer { deciding = [] }
        failure = nil
        var changed = false
        for record in listed {
            switch await send(record, approve: true) {
            case .done:
                deciding.remove(record.record)
            case .changed:
                changed = true
            case .failed(let message):
                failure = SyncApprovalFailure(record: nil, message: message)
                await settle()
                return
            }
        }
        if changed {
            failure = SyncApprovalFailure(record: nil, message: Self.changedAgainAllMessage)
        }
        await settle()
    }

    private enum Outcome {
        case done
        case changed
        case failed(String)
    }

    private func send(_ record: RecordApprovalInfo, approve: Bool) async -> Outcome {
        guard let engine = engine() else {
            return .failed(Self.saveFailedMessage)
        }
        do {
            try await engine.decideRecordApproval(record: record.record, digest: record.digest, approve: approve)
            return .done
        } catch let error as CoreError where Self.code(of: error) == "sync.unknown" {
            Self.logger.notice("An approval was settled before the decision reached it")
            return .done
        } catch let error as CoreError where Self.code(of: error) == "sync.changed" {
            return .changed
        } catch {
            Self.logger.error("Deciding an approval failed: \(error.publicLogShape, privacy: .public)")
            return .failed(Self.saveFailedMessage)
        }
    }

    // An approval writes the stores the core holds, which the Mac reads back, then the list is read again.
    private func settle() async {
        readCoreWrites()
        await refresh()
    }

    private func show(waiting count: Int, records read: [RecordApprovalInfo]) {
        if waiting != count {
            waiting = count
        }
        if records != read {
            records = read
        }
        if !hasRead {
            hasRead = true
        }
        if readFailed {
            readFailed = false
        }
        if let record = failure?.record, !read.contains(where: { $0.record == record }) {
            failure = nil
        }
    }

    static let changedAgainMessage = String(localized: "This item changed again. Review the new version, then choose.")
    static let changedAgainAllMessage = String(localized: "Some items changed again. Review the new versions, then choose.")
    static let saveFailedMessage = String(localized: "TablePro couldn't save your choice. Try again.")

    private static func code(of error: CoreError) -> String? {
        if case .Failed(let info) = error {
            return info.code
        }
        return nil
    }
}
