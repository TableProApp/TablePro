//
//  PluginDriverAdapter+Transactions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    var supportsTransactions: Bool {
        pluginDriver.supportsTransactions
    }

    @concurrent
    func beginTransaction() async throws {
        try await pluginDriver.beginTransaction()
    }

    @concurrent
    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await pluginDriver.beginTransaction(mode: mode)
    }

    @concurrent
    func commitTransaction() async throws {
        try await pluginDriver.commitTransaction()
    }

    @concurrent
    func rollbackTransaction() async throws {
        try await pluginDriver.rollbackTransaction()
    }

    @concurrent
    func sessionTransactionState() async -> PluginSessionTransactionState {
        await pluginDriver.sessionTransactionState()
    }
}
