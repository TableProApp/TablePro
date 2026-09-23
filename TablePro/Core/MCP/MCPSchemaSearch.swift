//
//  MCPSchemaSearch.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

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

    internal enum ColumnSearchOutcome: String, CaseIterable, Sendable {
        case searched
        case limitReached = "limit_reached"
        case failed
    }

    internal enum ColumnSearch: Equatable, Sendable {
        case searched(schema: String?)
        case limitReached
        case failed

        internal var outcome: ColumnSearchOutcome {
            switch self {
            case .searched: .searched
            case .limitReached: .limitReached
            case .failed: .failed
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
        let tableMatches = ordered(
            listing.tables.filter { $0.name.lowercased().contains(needle) },
            preferring: request.scope.schema
        ).map { table in
            Match.table(name: table.name, schema: table.schema, type: table.type)
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
        } catch let error as DatabaseError {
            throw error
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
        try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            let schema = (driver as? SchemaSwitchable)?.currentSchema
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
