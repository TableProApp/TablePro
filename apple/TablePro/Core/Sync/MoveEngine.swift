//
//  MoveEngine.swift
//  TablePro
//

import Foundation
import TableProFFI

// What a move between providers asks of the core's sync service (core ADR 0054, Moving between providers), so the
// moves are tested over a fake engine.
nonisolated protocol SyncMoveEngine: AnyObject, Sendable {
    func status() -> SyncStatusInfo
    func scopeStatuses() -> [ScopeStatusInfo]
    func syncNow(why: PassReasonTag) async throws
    func chooseProvider(provider: SyncProviderTag) async throws
    func setCategories(categories: SyncCategoriesArg) async throws
    func keyState() async throws -> KeyStateInfo
    func planMoveToService() async throws -> MovePlanInfo
    func moveToService() async throws
    func planMoveToIcloud() async throws -> MoveBackPlanInfo
    func moveToIcloud(confirmedDeletions: UInt64) async throws
    func chooseForNewIdentity(choice: NewIdentityChoiceTag) async throws
    func deleteIcloudZone() async throws
}

extension SyncService: SyncMoveEngine {}
