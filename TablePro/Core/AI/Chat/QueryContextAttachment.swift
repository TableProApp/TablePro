//
//  QueryContextAttachment.swift
//  TablePro
//

import Foundation

struct QueryContextAttachment: Codable, Equatable, Sendable {
    let id: UUID
    let connectionId: UUID
    let database: String
    let schema: String?
    let statement: String
    let explainPlan: String?
    var tableNames: [String]
    var unavailableTableNames: [String]
    var missingNames: [String]
    var rendered: String?

    init(
        id: UUID = UUID(),
        connectionId: UUID,
        database: String,
        schema: String?,
        statement: String,
        explainPlan: String? = nil,
        tableNames: [String] = [],
        unavailableTableNames: [String] = [],
        missingNames: [String] = [],
        rendered: String? = nil
    ) {
        self.id = id
        self.connectionId = connectionId
        self.database = database
        self.schema = schema
        self.statement = statement
        self.explainPlan = explainPlan
        self.tableNames = tableNames
        self.unavailableTableNames = unavailableTableNames
        self.missingNames = missingNames
        self.rendered = rendered
    }

    var isResolved: Bool {
        rendered != nil
    }

    var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    func resolved(with snapshot: QueryContextSnapshot) -> QueryContextAttachment {
        let rendering = QueryContextRenderer.rendering(snapshot)
        var copy = self
        copy.tableNames = rendering.sentTables.map(\.name)
        copy.unavailableTableNames = rendering.sentTables.filter(\.isUnavailable).map(\.name)
        copy.missingNames = snapshot.notFound + snapshot.outsideScope + snapshot.notDescribed + rendering.overBudgetNames
        copy.rendered = rendering.text
        return copy
    }

    var chipLabel: String {
        guard isResolved else { return String(localized: "Table structure") }
        guard !tableNames.isEmpty else { return String(localized: "No table structure") }
        let shown = tableNames.prefix(3).joined(separator: ", ")
        guard tableNames.count > 3 else { return shown }
        return String(format: String(localized: "%@ +%d more"), shown, tableNames.count - 3)
    }

    var helpText: String {
        guard isResolved else {
            return String(localized: "The structure of the tables this query uses is read when the request is sent.")
        }
        var lines: [String] = []
        if tableNames.isEmpty {
            lines.append(String(localized: "No table structure was sent."))
        } else {
            lines.append(String(format: String(localized: "Sent: %@"), tableNames.joined(separator: ", ")))
        }
        if !unavailableTableNames.isEmpty {
            lines.append(String(
                format: String(localized: "Could not be read: %@"),
                unavailableTableNames.joined(separator: ", ")
            ))
        }
        if !missingNames.isEmpty {
            lines.append(String(format: String(localized: "Not described: %@"), missingNames.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }
}
