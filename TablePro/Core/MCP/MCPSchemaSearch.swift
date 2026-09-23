//
//  MCPSchemaSearch.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// What `search_schema` finds for one term.
///
/// A caller that names no schema is asking where something lives, so on an engine whose tables
/// live in schemas the tables and views come from every one of them, through the same listing Open
/// Quickly and the sidebar filter search. It is read fresh on every call rather than taken from the
/// sidebar's copy, which only learns of catalog changes the app makes itself: a table a migration
/// created from a terminal would stay invisible to the tool until the next reconnect.
///
/// Columns come from one schema either way. Every schema's columns would be a catalog read of the
/// whole database for each search, so the result names the schema they came from, and a caller
/// looks in another by naming it.
internal enum MCPSchemaSearch {
    internal enum TableReach: Equatable, Sendable {
        case scopeSchema
        case everySchema(excluding: Set<String>)
    }

    internal struct Request: Sendable {
        internal let scope: DatabaseScope
        internal let term: String
        internal let limit: Int
        internal let tableReach: TableReach
    }

    internal enum Match: Equatable, Sendable {
        case table(name: String, schema: String?, type: TableInfo.TableType)
        case column(name: String, table: String, schema: String?, dataType: String)
    }

    internal enum ColumnSearch: Equatable, Sendable {
        case searched(schema: String?)
        case limitReached
        case failed

        internal static let outcomes = [Self.searched(schema: nil), .limitReached, .failed].map(\.outcome)

        internal var outcome: String {
            switch self {
            case .searched: "searched"
            case .limitReached: "limit_reached"
            case .failed: "failed"
            }
        }
    }

    internal struct Result: Equatable, Sendable {
        internal let matches: [Match]
        internal let isTruncated: Bool
        internal let unlistedSchemas: [String]
        internal let columnSearch: ColumnSearch
    }

    private struct ColumnRead: Sendable {
        let schema: String?
        let matches: [Match]
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPSchemaSearch")

    internal static func tableReach(
        schemaIsNamed: Bool,
        grouping: GroupingStrategy,
        systemSchemas: Set<String>
    ) -> TableReach {
        guard !schemaIsNamed, DatabaseTreeMetadataService.listsTablesPerSchema(grouping) else {
            return .scopeSchema
        }
        return .everySchema(excluding: systemSchemas)
    }

    internal static func run(_ request: Request, metadata: ScopedMetadataProviding) async throws -> Result {
        let needle = request.term.lowercased()
        let listing = try await tables(reaching: request.tableReach, in: request.scope, metadata: metadata)
        let listedSchema = request.tableReach == .scopeSchema ? request.scope.schema : nil
        let tableMatches = ordered(
            listing.tables.filter { $0.name.lowercased().contains(needle) },
            preferring: request.scope.schema
        ).map { table in
            Match.table(name: table.name, schema: table.schema ?? listedSchema, type: table.type)
        }
        let unlisted = listing.unlistedSchemas.sorted()

        guard tableMatches.count <= request.limit else {
            return Result(
                matches: Array(tableMatches.prefix(request.limit)),
                isTruncated: true,
                unlistedSchemas: unlisted,
                columnSearch: .limitReached
            )
        }

        let room = request.limit - tableMatches.count
        let columnRead: ColumnRead
        do {
            columnRead = try await columns(matching: needle, in: request.scope, metadata: metadata)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("[search] column read failed error=\(error.publicLogShape, privacy: .public)")
            return Result(
                matches: tableMatches,
                isTruncated: false,
                unlistedSchemas: unlisted,
                columnSearch: .failed
            )
        }
        return Result(
            matches: tableMatches + columnRead.matches.prefix(room),
            isTruncated: columnRead.matches.count > room,
            unlistedSchemas: unlisted,
            columnSearch: .searched(schema: columnRead.schema)
        )
    }

    /// The schema the caller is on leads, the way it wins ties in Open Quickly, so a limit that
    /// clips the matches clips other schemas' first.
    internal static func ordered(_ tables: [TableInfo], preferring schema: String?) -> [TableInfo] {
        let sorted = MCPConnectionBridge.sortedTables(tables)
        guard let schema else { return sorted }
        return sorted.filter { $0.schema == schema } + sorted.filter { $0.schema != schema }
    }

    private static func tables(
        reaching reach: TableReach,
        in scope: DatabaseScope,
        metadata: ScopedMetadataProviding
    ) async throws -> CatalogTableListing.Result {
        switch reach {
        case .everySchema(let excluded):
            return try await CatalogTableListing.tables(in: scope, excludingSchemas: excluded, metadata: metadata)
        case .scopeSchema:
            let schema = scope.schema
            let tables = try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                try await driver.fetchTables(schema: schema)
            }
            return CatalogTableListing.Result(tables: tables, unlistedSchemas: [])
        }
    }

    private static func columns(
        matching needle: String,
        in scope: DatabaseScope,
        metadata: ScopedMetadataProviding
    ) async throws -> ColumnRead {
        let fallbackSchema = scope.schema
        return try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            let schema = (driver as? SchemaSwitchable)?.currentSchema ?? fallbackSchema
            let allColumns = try await driver.fetchAllColumns()
            var matches: [Match] = []
            for table in allColumns.keys.sorted() {
                for column in allColumns[table] ?? [] where column.name.lowercased().contains(needle) {
                    matches.append(.column(name: column.name, table: table, schema: schema, dataType: column.dataType))
                }
            }
            return ColumnRead(schema: schema, matches: matches)
        }
    }
}
