//
//  TeamLibraryConflicts.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI

// The core engine's team conflicts (core ADR 0054, the `conflicts` table; 0051, Conflict rules), so the sheet's tests
// run over a fake engine.
nonisolated protocol TeamConflictEngine: AnyObject, Sendable {
    func conflicts() async throws -> [TeamConflictInfo]
    func resolveConflict(record: SyncRecordRef, keep: ConflictChoiceTag) async throws
}

extension SyncService: TeamConflictEngine {}

internal struct TeamLibraryConflictFailure: Equatable {
    let record: SyncRecordRef
    let message: String
}

// The team records whose fields this Mac and the team both changed, as the engine holds them until the person keeps one
// side. Decide Later only closes the sheet: the engine keeps both sides, and a later pull merges against them.
@MainActor
internal final class TeamLibraryConflictsModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryConflicts")

    @Published private(set) var conflicts: [TeamConflictInfo] = []
    @Published private(set) var teamNames: [String: String] = [:]
    @Published private(set) var resolving: SyncRecordRef?
    @Published private(set) var failure: TeamLibraryConflictFailure?

    private let engine: @MainActor () async throws -> any TeamConflictEngine
    private let loadTeamNames: @MainActor () async -> [String: String]?
    private let changes: AnyPublisher<Void, Never>
    private var changesCancellable: AnyCancellable?
    // Each fetch and each choice takes the next one, so an answer that started before the latest changes nothing.
    private var generation = 0
    private var askedForNames: Set<String> = []

    init(
        engine: @escaping @MainActor () async throws -> any TeamConflictEngine,
        changes: AnyPublisher<Void, Never>,
        teamNames: @escaping @MainActor () async -> [String: String]?
    ) {
        self.engine = engine
        self.changes = changes
        loadTeamNames = teamNames
    }

    // The engine's listener signals a change to its conflicts with its status.
    func start() {
        guard changesCancellable == nil else { return }
        changesCancellable = changes.sink { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func teamName(of scope: String) -> String? {
        teamNames[scope]
    }

    func failure(for record: SyncRecordRef) -> String? {
        failure?.record == record ? failure?.message : nil
    }

    // A failed read keeps the conflicts already shown.
    func refresh() async {
        generation += 1
        let started = generation
        let read: [TeamConflictInfo]
        do {
            read = try await engine().conflicts()
        } catch {
            Self.logger.error("Reading team conflicts failed: \(error.publicLogShape, privacy: .public)")
            return
        }
        guard started == generation else { return }
        if read != conflicts {
            conflicts = read
        }
        if let failure, !read.contains(where: { $0.record == failure.record }) {
            self.failure = nil
        }
        await nameTeams(of: read)
    }

    func resolve(_ conflict: TeamConflictInfo, keep: ConflictChoiceTag) async {
        guard resolving == nil else { return }
        resolving = conflict.record
        defer { resolving = nil }
        do {
            try await engine().resolveConflict(record: conflict.record, keep: keep)
        } catch let error as CoreError where Self.isGone(error) {
            Self.logger.notice("A team conflict was settled before the choice reached it")
        } catch {
            Self.logger.error("Resolving a team conflict failed: \(error.publicLogShape, privacy: .public)")
            failure = TeamLibraryConflictFailure(
                record: conflict.record,
                message: String(localized: "TablePro couldn't save your choice. Try again.")
            )
            return
        }
        generation += 1
        conflicts.removeAll { $0.record == conflict.record }
        if failure?.record == conflict.record {
            failure = nil
        }
        await refresh()
    }

    // Another pass took the record off the list between the read and the choice.
    private static func isGone(_ error: CoreError) -> Bool {
        if case .Failed(let info) = error {
            return info.code == "sync.unknown"
        }
        return false
    }

    // Asked once per team the profile has not named yet: a team the account left stays unnamed.
    private func nameTeams(of conflicts: [TeamConflictInfo]) async {
        let unnamed = Set(conflicts.map(\.record.scope)).subtracting(teamNames.keys).subtracting(askedForNames)
        guard !unnamed.isEmpty else { return }
        askedForNames.formUnion(unnamed)
        guard let names = await loadTeamNames() else {
            askedForNames.subtract(unnamed)
            return
        }
        let merged = teamNames.merging(names) { _, new in new }
        if merged != teamNames {
            teamNames = merged
        }
    }
}
