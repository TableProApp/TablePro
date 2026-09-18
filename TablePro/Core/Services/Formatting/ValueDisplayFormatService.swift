//
//  ValueDisplayFormatService.swift
//  TablePro
//
//  Resolves the effective display format per column: user override, else auto-detected.
//

import Foundation
import os

/// Owns which format a column is shown in, and where a user's choice is persisted.
///
/// Rendering a value under a format is a separate job that must not reach the preference layer;
/// it lives in `ValueDisplayFormatter`. Keeping the two apart is what lets the data grid's per
/// cell path stay free of storage, and it is why this type no longer exposes `applyFormat`.
@MainActor
final class ValueDisplayFormatService {
    static let shared = ValueDisplayFormatService()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ValueDisplayFormat")

    private let storage: ValueDisplayFormatStorage
    private var autoDetectedFormats: [String: ValueDisplayFormat] = [:]

    private(set) var overridesVersion: Int = 0

    init(storage: ValueDisplayFormatStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Effective Format Resolution

    func effectiveFormat(columnKey: String, scope: TableScope?) -> ValueDisplayFormat {
        if let scope,
           let overrides = storage.load(for: scope),
           let format = overrides[columnKey] {
            return format
        }

        if let format = autoDetectedFormats[scopedKey(columnKey: columnKey, scope: scope)] {
            return format
        }

        return .raw
    }

    func setAutoDetectedFormats(_ formats: [String: ValueDisplayFormat], scope: TableScope?) {
        let prefix = scopePrefix(scope: scope)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }

        for (columnKey, format) in formats {
            autoDetectedFormats[scopedKey(columnKey: columnKey, scope: scope)] = format
        }
    }

    func clearAutoDetectedFormats(scope: TableScope?) {
        let prefix = scopePrefix(scope: scope)
        autoDetectedFormats = autoDetectedFormats.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Scoping

    private func scopePrefix(scope: TableScope?) -> String {
        "\(scope?.storageComponent ?? "_")."
    }

    private func scopedKey(columnKey: String, scope: TableScope?) -> String {
        "\(scope?.storageComponent ?? "_").\(columnKey)"
    }

    // MARK: - Override Management

    func setOverride(
        _ format: ValueDisplayFormat?,
        columnKey: String,
        scope: TableScope
    ) {
        var overrides = storage.load(for: scope) ?? [:]

        if let format {
            overrides[columnKey] = format
        } else {
            overrides.removeValue(forKey: columnKey)
        }

        if overrides.isEmpty {
            storage.clear(for: scope)
        } else {
            storage.save(overrides, for: scope)
        }

        overridesVersion &+= 1
    }
}
