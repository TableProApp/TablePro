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
    func resolveConflict(record: SyncRecordRef, digest: String, keep: ConflictChoiceTag) async throws
    func approvals() async throws -> [RecordApprovalInfo]
    func decideApproval(record: SyncRecordRef, field: String, digest: String, approve: Bool) async throws
}

extension SyncService: TeamConflictEngine {}

internal struct TeamLibraryConflictFailure: Equatable {
    let record: SyncRecordRef
    let message: String
}

// The team records whose fields this Mac and the team both changed, as the engine holds them until the person keeps one
// side. Decide Later only closes the sheet: the engine keeps both sides, and a later pull merges against them. Team
// Library refreshes it with its own reads and ends it with the sign-in, so no conflict of an ended sign-in shows.
@MainActor
internal final class TeamLibraryConflictsModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryConflicts")

    @Published private(set) var conflicts: [TeamConflictInfo] = []
    @Published private(set) var teamNames: [String: String] = [:]
    // Who last changed the team's copy of each record, by `writerKey`.
    @Published private(set) var writers: [String: String] = [:]
    @Published private(set) var resolving: SyncRecordRef?
    @Published private(set) var failure: TeamLibraryConflictFailure?

    private let engine: @MainActor () async throws -> any TeamConflictEngine
    // Each fetch, each choice and each end takes the next one, so an answer that started before the latest changes
    // nothing.
    private var generation = 0
    // Each end of a sign-in takes the next one: a choice still out when it ends changes nothing after.
    private var epoch = 0

    init(engine: @escaping @MainActor () async throws -> any TeamConflictEngine) {
        self.engine = engine
    }

    // The names the team library holds for each team scope, and the writers of its items.
    func name(_ teams: [String: String], writers: [String: String]) {
        if teams != teamNames {
            teamNames = teams
        }
        if writers != self.writers {
            self.writers = writers
        }
    }

    nonisolated static func writerKey(scope: String, kind: String, id: String) -> String {
        "\(scope)\n\(kind)\n\(id.lowercased())"
    }

    func writer(of record: SyncRecordRef) -> String? {
        writers[Self.writerKey(scope: record.scope, kind: record.kind, id: record.recordId)]
    }

    // The sign-in ended: nothing of it shows from here on.
    func end() {
        generation += 1
        epoch += 1
        conflicts = []
        teamNames = [:]
        writers = [:]
        failure = nil
    }

    func teamName(of scope: String) -> String? {
        teamNames[scope]
    }

    func failure(for record: SyncRecordRef) -> String? {
        failure?.record == record ? failure?.message : nil
    }

    // A failed read keeps the conflicts already shown. With no service given, the one open now.
    func refresh(from service: (any TeamConflictEngine)? = nil) async {
        generation += 1
        let started = generation
        let read: [TeamConflictInfo]
        do {
            if let service {
                read = try await service.conflicts()
            } else {
                read = try await engine().conflicts()
            }
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
    }

    // The choice carries the digest of the conflict shown: one a pull has replaced since is refused, and the
    // replacement is shown instead, so a choice never keeps a version the person did not see.
    func resolve(_ conflict: TeamConflictInfo, keep: ConflictChoiceTag) async {
        guard resolving == nil else { return }
        resolving = conflict.record
        defer { resolving = nil }
        let epoch = epoch
        do {
            // The service the next sign-in opens is never told a choice made under this one.
            let engine = try await engine()
            guard epoch == self.epoch else { return }
            try await engine.resolveConflict(record: conflict.record, digest: conflict.digest, keep: keep)
            if keep == .keepTheirs {
                await approveTheirs(conflict, on: engine)
            }
        } catch let error as CoreError where Self.code(of: error) == "sync.unknown" {
            Self.logger.notice("A team conflict was settled before the choice reached it")
        } catch let error as CoreError where Self.code(of: error) == "sync.changed" {
            guard epoch == self.epoch else { return }
            await refresh()
            failure = TeamLibraryConflictFailure(
                record: conflict.record,
                message: String(localized: "This item changed again. Review the new version, then choose.")
            )
            return
        } catch {
            Self.logger.error("Resolving a team conflict failed: \(error.publicLogShape, privacy: .public)")
            guard epoch == self.epoch else { return }
            failure = TeamLibraryConflictFailure(
                record: conflict.record,
                message: String(localized: "TablePro couldn't save your choice. Try again.")
            )
            return
        }
        guard epoch == self.epoch else { return }
        generation += 1
        conflicts.removeAll { $0.record == conflict.record }
        if failure?.record == conflict.record {
            failure = nil
        }
        await refresh()
    }

    // Keep Theirs is the person's word on the team's values the sheet showed, so a pulled value of a field it showed
    // that waits for approval is approved with it, by the digest the approval list gave. One the team changed since
    // the sheet showed it, and a field the sheet did not show, wait in Review.
    private func approveTheirs(_ conflict: TeamConflictInfo, on engine: any TeamConflictEngine) async {
        guard let theirs = conflict.theirs.flatMap(Self.json) else { return }
        let waiting: [RecordApprovalInfo]
        do {
            waiting = try await engine.approvals()
        } catch {
            Self.logger.error("Reading the approvals after Keep Theirs failed: \(error.publicLogShape, privacy: .public)")
            return
        }
        guard let entry = waiting.first(where: { $0.record == conflict.record }) else { return }
        for field in entry.fields where Self.sheetShowed(field, of: conflict, theirs: theirs) {
            do {
                try await engine.decideApproval(record: conflict.record, field: field.field, digest: field.digest, approve: true)
            } catch {
                Self.logger.notice("A value Keep Theirs chose waits in Review: \(error.publicLogShape, privacy: .public)")
            }
        }
    }

    // A field of a member the sheet listed, whose pulled value is the team's value the sheet showed.
    nonisolated static func sheetShowed(_ field: FieldApprovalInfo, of conflict: TeamConflictInfo, theirs: Any) -> Bool {
        let tokens = pointerTokens(field.field)
        guard let member = tokens.first, conflict.fields.contains(member) else { return false }
        let shown = tokens.reduce(Optional(theirs)) { value, token in
            (value as? [String: Any])?[token]
        }
        switch (shown, field.pulled.flatMap(json)) {
        case (nil, nil):
            return true
        case let (shown?, pulled?):
            return canonical(shown).map { $0 == canonical(pulled) } ?? false
        default:
            return false
        }
    }

    // As JSON text with sorted members, so `true` never matches `1` the way Foundation's `isEqual` lets it.
    nonisolated private static func canonical(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // RFC 6901: "/a~1b/c~0d" reads as ["a/b", "c~d"].
    nonisolated static func pointerTokens(_ pointer: String) -> [String] {
        pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    nonisolated private static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func code(of error: CoreError) -> String? {
        if case .Failed(let info) = error {
            return info.code
        }
        return nil
    }
}
