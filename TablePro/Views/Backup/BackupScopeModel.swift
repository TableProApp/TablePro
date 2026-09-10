//
//  BackupScopeModel.swift
//  TablePro
//

import Foundation
import Observation

/// What the backup sheet is about to write, as the user has it set up.
///
/// A database is either whole or narrowed, and the difference is load bearing: a whole-database
/// dump carries views, routines and sequences that a list of tables does not, so a tree with every
/// box ticked resolves to `.wholeDatabase` rather than to an enumeration of every table in it.
@MainActor
@Observable
final class BackupScopeModel {
    enum ObjectLoad: Equatable {
        case notLoaded
        case loading
        case loaded
        case failed
    }

    struct ObjectRow: Identifiable, Equatable {
        let object: NativeDumpObject
        var isSelected: Bool

        var id: String { object.schema.map { "\($0).\(object.name)" } ?? object.name }
    }

    struct DatabaseRow: Identifiable, Equatable {
        let name: String
        /// What the tree shows. Differs from `name` only where the engine's identity for a database
        /// is a file path.
        var displayName: String = ""
        var isSelected: Bool
        var isExpanded: Bool = false
        var load: ObjectLoad = .notLoaded
        var objects: [ObjectRow] = []

        var id: String { name }

        var label: String { displayName.isEmpty ? name : displayName }

        var selectedObjects: [ObjectRow] {
            objects.filter(\.isSelected)
        }

        /// Every object ticked, or none loaded yet. Both mean "the whole database".
        var coversWholeDatabase: Bool {
            load != .loaded || objects.isEmpty || objects.allSatisfy(\.isSelected)
        }

        var isMixed: Bool {
            isSelected && load == .loaded && !objects.isEmpty && !objects.allSatisfy(\.isSelected)
        }
    }

    private(set) var rows: [DatabaseRow] = []
    private(set) var isLoadingDatabases = true

    let connection: DatabaseConnection
    let objectScope: NativeDumpObjectScope

    init(connection: DatabaseConnection, objectScope: NativeDumpObjectScope) {
        self.connection = connection
        self.objectScope = objectScope
    }

    // MARK: - Loading

    func loadDatabases(preselecting databases: Set<String>, activeDatabase: String?) async {
        isLoadingDatabases = true
        let containers = await BackupScopeLoader.databases(for: connection)
        let preselected = databases.isEmpty
            ? Set([activeDatabase].compactMap { $0 })
            : databases
        rows = containers.map { container in
            DatabaseRow(
                name: container.name,
                displayName: container.displayName,
                isSelected: preselected.contains(container.name)
            )
        }
        if rows.allSatisfy({ !$0.isSelected }), !rows.isEmpty {
            rows[0].isSelected = true
        }
        isLoadingDatabases = false
    }

    /// Reads one database's objects, once. Every object arrives ticked, because the sheet's default
    /// is the whole database and expanding a row is not by itself a decision to leave anything out.
    func loadObjects(for database: String) async {
        guard objectScope.allowsNarrowing else { return }
        guard let index = rows.firstIndex(where: { $0.name == database }) else { return }
        guard rows[index].load == .notLoaded else { return }
        rows[index].load = .loading
        let objects = await BackupScopeLoader.objects(in: database, connection: connection)
        guard let current = rows.firstIndex(where: { $0.name == database }) else { return }
        rows[current].objects = objects.map { ObjectRow(object: $0, isSelected: true) }
        rows[current].load = objects.isEmpty ? .failed : .loaded
    }

    // MARK: - Selection

    func setExpanded(_ expanded: Bool, database: String) {
        guard let index = rows.firstIndex(where: { $0.name == database }) else { return }
        rows[index].isExpanded = expanded
    }

    func toggleDatabase(_ database: String) {
        rows = Self.togglingDatabase(database, in: rows)
    }

    func toggleObject(_ id: String, in database: String) {
        rows = Self.togglingObject(id, in: database, rows: rows)
    }

    /// Ticking a mixed database means "all of it", which is the state a user reaches by unticking
    /// a few tables and then changing their mind.
    static func togglingDatabase(
        _ database: String,
        in rows: [DatabaseRow]
    ) -> [DatabaseRow] {
        var rows = rows
        guard let index = rows.firstIndex(where: { $0.name == database }) else { return rows }
        let turningOn = !rows[index].isSelected || rows[index].isMixed
        rows[index].isSelected = turningOn
        for objectIndex in rows[index].objects.indices {
            rows[index].objects[objectIndex].isSelected = turningOn
        }
        return rows
    }

    /// Unticking the last object is a decision to leave the database out, not a decision to back it
    /// up empty. Ticking one again brings the database back carrying only that object.
    static func togglingObject(
        _ id: String,
        in database: String,
        rows: [DatabaseRow]
    ) -> [DatabaseRow] {
        var rows = rows
        guard let index = rows.firstIndex(where: { $0.name == database }) else { return rows }
        guard let objectIndex = rows[index].objects.firstIndex(where: { $0.id == id }) else { return rows }
        rows[index].objects[objectIndex].isSelected.toggle()
        rows[index].isSelected = rows[index].objects.contains(where: \.isSelected)
        return rows
    }

    // MARK: - Derived

    var selectedDatabases: [DatabaseRow] {
        rows.filter(\.isSelected)
    }

    var isNarrowed: Bool {
        selectedDatabases.contains { !$0.coversWholeDatabase }
    }

    var canRun: Bool {
        !selectedDatabases.isEmpty
    }

    func scopes() -> [(database: String, label: String, scope: NativeDumpScope)] {
        Self.scopes(in: rows)
    }

    func summary() -> String {
        Self.summary(for: rows, objectScope: objectScope)
    }

    /// One entry per selected database, in tree order.
    ///
    /// A database with every object ticked resolves to `.wholeDatabase` rather than to a list of
    /// all of them, because a whole-database dump also carries the views, routines and sequences
    /// that naming tables leaves out.
    static func scopes(
        in rows: [DatabaseRow]
    ) -> [(database: String, label: String, scope: NativeDumpScope)] {
        rows.filter(\.isSelected).map { row in
            guard !row.coversWholeDatabase else {
                return (row.name, row.label, NativeDumpScope.wholeDatabase)
            }
            return (row.name, row.label, .objects(row.selectedObjects.map(\.object)))
        }
    }

    /// What the footer says the run will produce.
    static func summary(for rows: [DatabaseRow], objectScope: NativeDumpObjectScope) -> String {
        let databases = rows.filter(\.isSelected)
        guard !databases.isEmpty else {
            return String(localized: "Nothing selected.")
        }
        guard databases.count == 1 else {
            return String(
                format: String(localized: "Writes %lld files, one for each database."),
                Int64(databases.count)
            )
        }
        let row = databases[0]
        guard !row.coversWholeDatabase else { return String(localized: "Writes 1 file.") }
        let count = row.selectedObjects.count
        /// Agreement follows the total, not the selection: "1 of 2 tables" is the phrase, not
        /// "1 of 2 table".
        let noun = row.objects.count == 1 ? objectScope.singularUnitNoun : objectScope.unitNoun
        return String(
            format: String(localized: "Writes 1 file with %1$lld of %2$lld %3$@."),
            Int64(count),
            Int64(row.objects.count),
            noun
        )
    }
}
