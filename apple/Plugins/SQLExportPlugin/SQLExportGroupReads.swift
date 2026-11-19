import Foundation
import os
import TableProPluginKit

// A lone object, a failed group read or one at the row limit reads each object alone, so a failure still names its table.
nonisolated final class SQLExportGroupReads {
    private final class GroupRead<Value> {
        let kind: PluginExportBulkReads
        // Columns and foreign keys are read by group from every source and for any group size, as the dump always has.
        let readsEveryGroup: Bool
        let groupSizes: [[UInt8]: Int]
        let fetch: (String) async throws -> [String: [Value]]
        var answers: [[UInt8]: [String: [Value]]?] = [:]

        init(
            kind: PluginExportBulkReads,
            objects: [PluginExportTable],
            readsEveryGroup: Bool = false,
            fetch: @escaping (String) async throws -> [String: [Value]]
        ) {
            self.kind = kind
            self.readsEveryGroup = readsEveryGroup
            self.groupSizes = Dictionary(grouping: objects) { PluginExportSpelling.key($0.databaseName) }
                .mapValues(\.count)
            self.fetch = fetch
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportPlugin")

    private let dataSource: any PluginExportDataSource
    private let progress: PluginExportProgress
    private let rowLimit: Int
    private let columnReads: GroupRead<PluginColumnInfo>
    private let foreignKeyReads: GroupRead<PluginForeignKeyInfo>
    private let indexDDLReads: GroupRead<String>
    private let commentDDLReads: GroupRead<String>
    private let sequenceReads: GroupRead<PluginSequenceInfo>
    private let typeReads: GroupRead<PluginEnumTypeInfo>

    init(
        dataSource: any PluginExportDataSource,
        progress: PluginExportProgress,
        tables: [PluginExportTable],
        commentedObjects: [PluginExportTable],
        indexedObjects: [PluginExportTable],
        rowLimit: Int = PluginRowLimits.emergencyMax
    ) {
        self.dataSource = dataSource
        self.progress = progress
        self.rowLimit = rowLimit
        columnReads = GroupRead(kind: .columns, objects: [], readsEveryGroup: true) {
            try await dataSource.fetchAllColumns(databaseName: $0)
        }
        foreignKeyReads = GroupRead(kind: .foreignKeys, objects: [], readsEveryGroup: true) {
            try await dataSource.fetchAllForeignKeys(databaseName: $0)
        }
        indexDDLReads = GroupRead(kind: .indexDDL, objects: indexedObjects) {
            try await dataSource.fetchAllIndexDDL(databaseName: $0)
        }
        commentDDLReads = GroupRead(kind: .commentDDL, objects: commentedObjects) {
            try await dataSource.fetchAllCommentDDL(databaseName: $0)
        }
        sequenceReads = GroupRead(kind: .dependentSequences, objects: tables) {
            try await dataSource.fetchAllDependentSequences(databaseName: $0)
        }
        typeReads = GroupRead(kind: .dependentTypes, objects: tables) {
            try await dataSource.fetchAllDependentTypes(databaseName: $0)
        }
    }

    func columns(for table: PluginExportTable) async throws -> [PluginColumnInfo] {
        try await answer(columnReads, for: table) {
            try await dataSource.fetchColumns(table: table.name, databaseName: table.databaseName)
        }
    }

    func foreignKeys(for table: PluginExportTable) async throws -> [PluginForeignKeyInfo] {
        try await answer(foreignKeyReads, for: table) {
            try await dataSource.fetchForeignKeys(table: table.name, databaseName: table.databaseName)
        }
    }

    func indexDDL(for object: PluginExportTable) async throws -> [String] {
        try await answer(indexDDLReads, for: object) {
            try await dataSource.fetchIndexDDL(table: object.name, databaseName: object.databaseName)
        }
    }

    func commentDDL(for object: PluginExportTable) async throws -> [String] {
        try await answer(commentDDLReads, for: object) {
            try await dataSource.fetchCommentDDL(table: object.name, databaseName: object.databaseName)
        }
    }

    func dependentSequences(for table: PluginExportTable) async throws -> [PluginSequenceInfo] {
        try await answer(sequenceReads, for: table) {
            try await dataSource.fetchDependentSequences(table: table.name, databaseName: table.databaseName)
        }
    }

    func dependentTypes(for table: PluginExportTable) async throws -> [PluginEnumTypeInfo] {
        try await answer(typeReads, for: table) {
            try await dataSource.fetchDependentTypes(table: table.name, databaseName: table.databaseName)
        }
    }

    private func answer<Value>(
        _ read: GroupRead<Value>,
        for object: PluginExportTable,
        alone: () async throws -> [Value]
    ) async throws -> [Value] {
        guard let group = try await groupAnswer(read, databaseName: object.databaseName) else {
            return try await alone()
        }
        switch PluginExportSpelling.entry(object.name, in: group) {
        case .answered(let values): return values
        case .absent: return []
        case .otherSpelling: return try await alone()
        }
    }

    private func groupAnswer<Value>(
        _ read: GroupRead<Value>,
        databaseName: String
    ) async throws -> [String: [Value]]? {
        let key = PluginExportSpelling.key(databaseName)
        if let known = read.answers[key] { return known }
        let reads = read.readsEveryGroup
            || (dataSource.bulkReads.contains(read.kind) && read.groupSizes[key, default: 0] > 1)
        guard reads else {
            read.answers.updateValue(nil, forKey: key)
            return nil
        }
        do {
            let fetched = try await read.fetch(databaseName)
            let complete = fetched.values.reduce(0) { $0 + $1.count } < rowLimit ? fetched : nil
            read.answers.updateValue(complete, forKey: key)
            return complete
        } catch {
            read.answers.updateValue(nil, forKey: key)
            if error is CancellationError || error is PluginExportCancellationError { throw error }
            try progress.checkCancellation()
            Self.logger.warning("Group read failed, reading each object alone: \(error.localizedDescription)")
            return nil
        }
    }
}
