//
//  MySQLPluginDriver+ServerObjects.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

nonisolated internal enum MySQLEvents {
    static let kindId = "event"

    static var kind: PluginServerObjectKind {
        PluginServerObjectKind(
            id: kindId,
            displayName: String(localized: "Event"),
            pluralDisplayName: String(localized: "Events"),
            iconName: "calendar.badge.clock",
            scope: .container
        )
    }

    // TiDB lists `EVENTS` with no rows and OceanBase is not established, so only these two declare it.
    static func isDeclared(flavor: MySQLServerFlavor, banner: String?) -> Bool {
        guard flavor == .mysql || flavor == .mariadb else { return false }
        return MySQLServerVersion.hasPartitionAndEventCatalogs(banner: banner, flavor: flavor)
    }
}

// Reads `MySQLObjectQueries.eventDetails` rows: name, type, status, schema, then the schedule columns.
nonisolated internal enum MySQLEventRows {
    static func objects(from rows: [[PluginCellValue]], scheduler: String? = nil) -> [PluginServerObjectInfo] {
        rows.compactMap { object(from: $0, scheduler: scheduler) }
    }

    // `scheduler` is `@@global.event_scheduler`, read once beside the rows; nil leaves the attribute out.
    static func object(from row: [PluginCellValue], scheduler: String? = nil) -> PluginServerObjectInfo? {
        guard let name = text(row, 0) else { return nil }
        let isRecurring = text(row, 1)?.uppercased() == "RECURRING"
        let status = text(row, 2)?.uppercased()
        var attributes: [PluginObjectAttribute] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            attributes.append(PluginObjectAttribute(label: label, value: value))
        }
        add(String(localized: "Schedule"), schedule(
            isRecurring: isRecurring, executeAt: text(row, 4), intervalValue: text(row, 5), intervalField: text(row, 6)
        ))
        add(String(localized: "Status"), status.map(statusLabel))
        add(String(localized: "Starts"), text(row, 7))
        add(String(localized: "Ends"), text(row, 8))
        add(String(localized: "On Completion"), text(row, 9))
        add(String(localized: "Last Executed"), text(row, 10))
        add(String(localized: "Definer"), text(row, 11))
        add(String(localized: "Comment"), text(row, 12))
        add(String(localized: "Event Scheduler"), scheduler)
        return PluginServerObjectInfo(
            kindId: MySQLEvents.kindId,
            name: name,
            schema: text(row, 3),
            detail: isRecurring ? String(localized: "Recurring") : String(localized: "One Time"),
            isEnabled: status.map { $0 == "ENABLED" },
            attributes: attributes
        )
    }

    // The schedule in the clause `CREATE EVENT` takes, quoting a composite interval as the server does.
    static func schedule(isRecurring: Bool, executeAt: String?, intervalValue: String?, intervalField: String?) -> String? {
        guard isRecurring else { return executeAt.map { "AT '\($0)'" } }
        guard let intervalValue, let intervalField else { return nil }
        let value = intervalValue.allSatisfy(\.isNumber) ? intervalValue : "'\(intervalValue)'"
        return "EVERY \(value) \(intervalField)"
    }

    // 8.2 renamed SLAVESIDE_DISABLED to REPLICA_SIDE_DISABLED; both mean the replica does not run it.
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ENABLED": return String(localized: "Enabled")
        case "DISABLED": return String(localized: "Disabled")
        case "SLAVESIDE_DISABLED", "REPLICA_SIDE_DISABLED": return String(localized: "Disabled on Replica")
        default: return status
        }
    }

    // The catalog compares names without case, so an exact spelling wins over another the read also matched.
    static func row(named name: String, in rows: [[PluginCellValue]]) -> [PluginCellValue]? {
        rows.first { $0[safe: 0]?.asText == name } ?? rows.first
    }

    private static func text(_ row: [PluginCellValue], _ index: Int) -> String? {
        guard let value = row[safe: index]?.asText, !value.isEmpty else { return nil }
        return value
    }
}

internal extension MySQLPluginDriver {
    var serverObjectKinds: [PluginServerObjectKind] {
        let identity = serverIdentity
        return MySQLEvents.isDeclared(flavor: identity.flavor, banner: identity.banner) ? [MySQLEvents.kind] : []
    }

    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [PluginServerObjectInfo] {
        let identity = serverIdentity
        guard kindId == MySQLEvents.kindId, MySQLEvents.isDeclared(flavor: identity.flavor, banner: identity.banner) else {
            return []
        }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let result = try await execute(
            ownStatement: MySQLObjectQueries.eventDetails(schema: effectiveSchema(schema), exactSchema: exactSchema)
        )
        guard !result.rows.isEmpty else { return [] }
        return MySQLEventRows.objects(from: result.rows, scheduler: await eventScheduler())
    }

    // The tab reads the event's row again, so its attributes follow an ALTER EVENT as its DDL does.
    func fetchServerObject(_ object: PluginServerObjectInfo) async throws -> PluginServerObjectInfo {
        guard object.kindId == MySQLEvents.kindId else { throw PluginObjectSourceError.unsupported(object.name) }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let result = try await execute(ownStatement: MySQLObjectQueries.eventDetails(
            schema: effectiveSchema(object.schema), name: object.name, exactSchema: exactSchema
        ))
        guard let row = MySQLEventRows.row(named: object.name, in: result.rows),
              let fresh = MySQLEventRows.object(from: row, scheduler: await eventScheduler())
        else { throw PluginObjectSourceError.notFound(object.name) }
        let definition = try await fetchEventDDL(PluginEventInfo(name: fresh.name, schema: fresh.schema))
        return PluginServerObjectInfo(
            kindId: fresh.kindId,
            name: fresh.name,
            schema: fresh.schema,
            identity: object.identity,
            detail: fresh.detail,
            isEnabled: fresh.isEnabled,
            definition: definition,
            attributes: fresh.attributes
        )
    }

    // A server or proxy without the variable loses this one attribute, never the list.
    private func eventScheduler() async -> String? {
        guard let result = try? await execute(ownStatement: MySQLObjectQueries.eventScheduler) else { return nil }
        return result.rows.first?[safe: 0]?.asText
    }
}
