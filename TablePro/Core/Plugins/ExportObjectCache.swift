//
//  ExportObjectCache.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One database's routine, trigger and type lists, held for the life of a single export.
///
/// A driver addresses a routine, trigger or type through the info object it handed out, and that
/// object carries an opaque identity an export item cannot reproduce. Every DDL read therefore has
/// to match its item back onto the driver's own object, and without this each read would re-list
/// the whole database.
actor ExportObjectCache {
    private var routinesByDatabase: [String: [PluginRoutineInfo]] = [:]
    private var triggersByDatabase: [String: [PluginTriggerInfo]] = [:]
    private var userTypesByDatabase: [String: [PluginUserDefinedTypeInfo]] = [:]
    private var eventsByDatabase: [String: [PluginEventInfo]] = [:]
    private var sequencesByDatabase: [String: [PluginSequenceInfo]] = [:]

    func routines(
        forDatabase database: String,
        load: () async throws -> [PluginRoutineInfo]
    ) async throws -> [PluginRoutineInfo] {
        if let cached = routinesByDatabase[database] { return cached }
        let loaded = try await load()
        routinesByDatabase[database] = loaded
        return loaded
    }

    func triggers(
        forDatabase database: String,
        load: () async throws -> [PluginTriggerInfo]
    ) async throws -> [PluginTriggerInfo] {
        if let cached = triggersByDatabase[database] { return cached }
        let loaded = try await load()
        triggersByDatabase[database] = loaded
        return loaded
    }

    func events(
        forDatabase database: String,
        load: () async throws -> [PluginEventInfo]
    ) async throws -> [PluginEventInfo] {
        if let cached = eventsByDatabase[database] { return cached }
        let loaded = try await load()
        eventsByDatabase[database] = loaded
        return loaded
    }

    func sequences(
        forDatabase database: String,
        load: () async throws -> [PluginSequenceInfo]
    ) async throws -> [PluginSequenceInfo] {
        if let cached = sequencesByDatabase[database] { return cached }
        let loaded = try await load()
        sequencesByDatabase[database] = loaded
        return loaded
    }

    func userTypes(
        forDatabase database: String,
        load: () async throws -> [PluginUserDefinedTypeInfo]
    ) async throws -> [PluginUserDefinedTypeInfo] {
        if let cached = userTypesByDatabase[database] { return cached }
        let loaded = try await load()
        userTypesByDatabase[database] = loaded
        return loaded
    }
}
