//
//  ObjectListingRows.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The object one row of an Objects tab lists, with what a row command needs to reach it again.
internal enum ObjectListingItem: Hashable, Sendable {
    /// A table, view or other relation: it opens in a grid.
    case relation(name: String, schema: String?, type: TableInfo.TableType)
    /// A routine, trigger or type: it opens as its source.
    case sourced(DatabaseObjectRef)

    var name: String {
        switch self {
        case .relation(let name, _, _): return name
        case .sourced(let ref): return ref.name
        }
    }

    /// Nil for a relation the source viewer cannot read: a table's definition is on its Structure tab.
    func sourceRef(database: String) -> DatabaseObjectRef? {
        switch self {
        case .relation(let name, let schema, let type):
            let table = TableInfo(name: name, type: type, rowCount: nil, schema: schema)
            return DatabaseObjectRef(relation: table, database: database, schema: schema)
        case .sourced(let ref):
            return ref
        }
    }
}

extension ObjectListingItem {
    /// One object from one read to the next. Counts and comments change between reads, and overloads
    /// or triggers on different tables share a name, so the key is the name, the schema and what
    /// tells those apart.
    struct Key: Hashable {
        let name: String
        let schema: String?
        let table: String?
        let argumentSignature: String?
    }

    var key: Key {
        switch self {
        case .relation(let name, let schema, _):
            return Key(name: name, schema: schema, table: nil, argumentSignature: nil)
        case .sourced(let ref):
            return Key(name: ref.name, schema: ref.schema, table: ref.table, argumentSignature: ref.argumentSignature)
        }
    }
}

extension TableListing {
    /// A list the sidebar commits again unchanged has nothing for the grid to redraw.
    func showsSameRows(as other: TableListing) -> Bool {
        rows.columns == other.rows.columns && columnKeys == other.columnKeys
            && rows.rows == other.rows.rows && items == other.items
    }
}

/// Where a plugin's table listing names its objects: the plugins alias the columns `name`,
/// `schema` or `schema_name`, and `kind`. A shell command's listing has none of them.
internal struct ObjectListingColumns: Equatable {
    let name: Int
    let schema: Int?
    let kind: Int?

    init?(columns: [String]) {
        let lowered = columns.map { $0.lowercased() }
        guard let name = lowered.firstIndex(of: "name") else { return nil }
        self.name = name
        schema = lowered.firstIndex(of: "schema") ?? lowered.firstIndex(of: "schema_name")
        kind = lowered.firstIndex(of: "kind")
    }

    /// `readsSchemaColumn` is off where the engine's namespace is the database: MySQL's `schema`
    /// column names the database, and a table opened with it as a schema is a second tab for it.
    func items(in rows: TableRows, containerSchema: String?, readsSchemaColumn: Bool) -> [RowID: ObjectListingItem] {
        var items: [RowID: ObjectListingItem] = [:]
        for row in rows.rows {
            guard let name = row[self.name].asText, !name.isEmpty else { continue }
            let listed = readsSchemaColumn ? schema.flatMap { row[$0].asText?.nilIfEmpty } : nil
            let type = Self.relationType(kind.flatMap { row[$0].asText })
            items[row.id] = .relation(name: name, schema: listed ?? containerSchema, type: type)
        }
        return items
    }

    /// The Tables kind lists tables only. Views, sequences and the other relations each have a kind of
    /// their own, as they have a group in the sidebar, and a listing without a kind column keeps every row.
    func tableRows(of rows: [[PluginCellValue]]) -> [[PluginCellValue]] {
        guard let kind else { return rows }
        return rows.filter { row in
            let word = row.indices.contains(kind) ? row[kind].asText : nil
            return SidebarObjectKind.resolve(tableType: Self.relationType(word)) == .table
        }
    }

    /// The plugins alias their listing columns for SQL, not for reading, so a known alias reads as words.
    /// An alias this does not know keeps the plugin's spelling.
    static func displayTitle(for column: String) -> String {
        ObjectListingField(alias: column)?.title ?? column
    }

    /// An unknown word, such as a ClickHouse engine name, reads as a table: only a view must not
    /// open as an editable grid.
    static func relationType(_ kind: String?) -> TableInfo.TableType {
        switch kind?.trimmingCharacters(in: .whitespaces).uppercased() ?? "" {
        case "VIEW", "SYSTEM VIEW": return .view
        case "MATERIALIZED VIEW", "MATERIALIZEDVIEW": return .materializedView
        case "FOREIGN TABLE": return .foreignTable
        case "SEQUENCE": return .sequence
        default: return .table
        }
    }
}

/// One kind's objects as the sidebar reads them, before they become rows.
internal enum CatalogObjectList: Sendable, Equatable {
    case relations([TableInfo])
    case routines([RoutineInfo])
    case triggers([TriggerInfo])
    case types([UserDefinedTypeInfo])
}

/// The Objects tab's rows for every kind but Tables, built from the lists the sidebar shows.
internal enum ObjectListingRows {
    internal static func listing(kind: SidebarObjectKind, from list: CatalogObjectList, scope: DatabaseScope) -> TableListing {
        let database = scope.database
        let schema = scope.schema
        switch list {
        case .relations(let tables):
            let columns: [ListingColumn<TableInfo>] = [
                ListingColumn("name", String(localized: "Name"), isOptional: false) { $0.name },
                ListingColumn("schema", String(localized: "Schema")) { $0.schema ?? schema },
                ListingColumn("estimated_rows", String(localized: "Rows"), isCount: true) { $0.rowCount.map(String.init) },
                ListingColumn("comment", String(localized: "Comment")) { $0.comment?.nilIfEmpty },
            ]
            let matching = tables.filter { SidebarObjectKind.resolve(tableType: $0.type) == kind }
            return build(matching, columns: columns) { .relation(name: $0.name, schema: schema ?? $0.schema, type: $0.type) }
        case .routines(let routines):
            let columns: [ListingColumn<RoutineInfo>] = [
                ListingColumn("name", String(localized: "Name"), isOptional: false) { $0.name },
                ListingColumn("schema", String(localized: "Schema")) { $0.schema ?? schema },
                ListingColumn("arguments", String(localized: "Arguments")) { $0.argumentSignature?.nilIfEmpty },
                ListingColumn("returns", String(localized: "Returns")) { $0.returnType?.nilIfEmpty },
                ListingColumn("language", String(localized: "Language")) { $0.language?.nilIfEmpty },
            ]
            let matching = routines.filter { $0.kind.sidebarObjectKind == kind }
            return build(matching, columns: columns) { .sourced(DatabaseObjectRef(routine: $0, database: database)) }
        case .triggers(let triggers):
            let columns: [ListingColumn<TriggerInfo>] = [
                ListingColumn("name", String(localized: "Name"), isOptional: false) { $0.name },
                ListingColumn("table", String(localized: "Table")) { $0.table?.nilIfEmpty },
                ListingColumn("timing", String(localized: "Timing")) { $0.timing.nilIfEmpty },
                ListingColumn("event", String(localized: "Event")) { $0.event.nilIfEmpty },
                ListingColumn("enabled", String(localized: "Enabled")) { trigger in
                    trigger.enabled.map { $0 ? String(localized: "Yes") : String(localized: "No") }
                },
            ]
            return build(triggers, columns: columns) { .sourced(DatabaseObjectRef(trigger: $0, database: database)) }
        case .types(let types):
            let columns: [ListingColumn<UserDefinedTypeInfo>] = [
                ListingColumn("name", String(localized: "Name"), isOptional: false) { $0.name },
                ListingColumn("schema", String(localized: "Schema")) { $0.schema ?? schema },
            ]
            return build(types, columns: columns) { .sourced(DatabaseObjectRef(userType: $0, database: database)) }
        }
    }

    // Row ids match `TableRows.from`, so each row's object is keyed by the row the grid shows.
    private static func build<Object>(
        _ objects: [Object],
        columns: [ListingColumn<Object>],
        item: (Object) -> ObjectListingItem
    ) -> TableListing {
        let kept = columns.filter { column in
            !column.isOptional || objects.contains { column.value($0) != nil }
        }
        let rows = objects.map { object in kept.map { PluginCellValue.fromOptional($0.value(object)) } }
        let types: [ColumnType] = kept.map { $0.isCount ? .integer(rawType: nil) : .text(rawType: nil) }
        var items: [RowID: ObjectListingItem] = [:]
        for (index, object) in objects.enumerated() {
            items[.existing(index)] = item(object)
        }
        return TableListing(
            rows: TableRows.from(queryRows: rows, columns: kept.map(\.title), columnTypes: types),
            isIncomplete: false,
            statusMessage: nil,
            items: items,
            columnKeys: kept.map(\.key)
        )
    }
}

/// A column no object has a value for says nothing, as a Schema column does on an engine without schemas.
private struct ListingColumn<Object> {
    let key: String
    let title: String
    let isOptional: Bool
    let isCount: Bool
    let value: (Object) -> String?

    init(_ key: String, _ title: String, isOptional: Bool = true, isCount: Bool = false, value: @escaping (Object) -> String?) {
        self.key = key
        self.title = title
        self.isOptional = isOptional
        self.isCount = isCount
        self.value = value
    }
}

/// The name filter works on the rows a listing already holds and fetches nothing.
internal enum ObjectListingFilter {
    /// Blank text, or a listing with no names to match, keeps every row.
    static func rows(of listing: TableListing, matching text: String) -> TableRows {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !listing.items.isEmpty else { return listing.rows }
        let hidden = Set(listing.rows.rows.compactMap { row -> RowID? in
            guard let name = listing.items[row.id]?.name, matches(name, needle) else { return row.id }
            return nil
        })
        var shown = listing.rows
        shown.remove(rowIDs: hidden)
        return shown
    }

    /// Whether `name` holds the filter text, ignoring case, accents and the spaces around the text.
    static func keeps(_ name: String, matching text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || matches(name, needle)
    }

    private static func matches(_ name: String, _ needle: String) -> Bool {
        name.localizedStandardContains(needle)
    }
}
