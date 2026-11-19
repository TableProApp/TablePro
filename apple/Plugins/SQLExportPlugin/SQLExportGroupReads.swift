import Foundation
import os
import TableProPluginKit

// A lone object, a failed group read or one at the row limit reads each object alone, so a failure still names its table.
nonisolated final class SQLExportGroupReads {
    private final class GroupRead<Value> {
        let kind: PluginExportBulkReads
        let groupSizes: [String: Int]
        let fetch: (String) async throws -> [String: [Value]]
        var answers: [String: [String: [Value]]?] = [:]

        init(
            kind: PluginExportBulkReads,
            objects: [PluginExportTable],
            fetch: @escaping (String) async throws -> [String: [Value]]
        ) {
            self.kind = kind
            self.groupSizes = Dictionary(grouping: objects, by: \.databaseName).mapValues(\.count)
            self.fetch = fetch
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportPlugin")

    private let dataSource: any PluginExportDataSource
    private let progress: PluginExportProgress
    private let rowLimit: Int
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
        guard let index = group.index(forKey: object.name) else { return [] }
        // Swift equates NFC and NFD spellings the server keeps apart, so a key spelled otherwise is another relation's.
        guard group[index].key.utf8.elementsEqual(object.name.utf8) else { return try await alone() }
        return group[index].value
    }

    private func groupAnswer<Value>(
        _ read: GroupRead<Value>,
        databaseName: String
    ) async throws -> [String: [Value]]? {
        if let known = read.answers[databaseName] { return known }
        guard dataSource.bulkReads.contains(read.kind), read.groupSizes[databaseName, default: 0] > 1 else {
            read.answers.updateValue(nil, forKey: databaseName)
            return nil
        }
        do {
            let fetched = try await read.fetch(databaseName)
            let complete = fetched.values.reduce(0) { $0 + $1.count } < rowLimit ? fetched : nil
            read.answers.updateValue(complete, forKey: databaseName)
            return complete
        } catch {
            read.answers.updateValue(nil, forKey: databaseName)
            if error is CancellationError || error is PluginExportCancellationError { throw error }
            try progress.checkCancellation()
            Self.logger.warning("Group read failed, reading each object alone: \(error.localizedDescription)")
            return nil
        }
    }
}
