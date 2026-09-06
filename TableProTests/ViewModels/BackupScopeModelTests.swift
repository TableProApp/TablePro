//
//  BackupScopeModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Backup scope selection")
@MainActor
struct BackupScopeModelTests {

    private func row(
        _ name: String,
        selected: Bool,
        objects: [(String, Bool)] = [],
        load: BackupScopeModel.ObjectLoad = .loaded
    ) -> BackupScopeModel.DatabaseRow {
        BackupScopeModel.DatabaseRow(
            name: name,
            displayName: "",
            isSelected: selected,
            isExpanded: false,
            load: objects.isEmpty && load == .loaded ? .notLoaded : load,
            objects: objects.map {
                BackupScopeModel.ObjectRow(object: NativeDumpObject(name: $0.0), isSelected: $0.1)
            }
        )
    }

    /// A whole-database dump carries views, routines and sequences that naming every table does
    /// not, so a fully ticked tree must not resolve to an enumeration of its tables.
    @Test("Every object ticked means the whole database, not a list of all of them")
    func fullSelectionIsWholeDatabase() {
        let rows = [row("sales", selected: true, objects: [("orders", true), ("carts", true)])]
        let scopes = BackupScopeModel.scopes(in: rows)
        #expect(scopes.count == 1)
        #expect(scopes[0].scope.isWholeDatabase)
    }

    @Test("A database whose objects were never read is the whole database")
    func unloadedIsWholeDatabase() {
        let rows = [row("sales", selected: true)]
        #expect(BackupScopeModel.scopes(in: rows)[0].scope.isWholeDatabase)
    }

    @Test("Unticking one object narrows that database and leaves the others whole")
    func partialSelectionNarrows() {
        let rows = [
            row("sales", selected: true, objects: [("orders", true), ("carts", false)]),
            row("billing", selected: true, objects: [("invoices", true)])
        ]
        let scopes = BackupScopeModel.scopes(in: rows)
        #expect(scopes.map(\.database) == ["sales", "billing"])
        #expect(scopes[0].scope.objects.map(\.name) == ["orders"])
        #expect(scopes[1].scope.isWholeDatabase)
    }

    @Test("An unticked database is left out of the run entirely")
    func untickedDatabaseIsExcluded() {
        let rows = [
            row("sales", selected: false, objects: [("orders", true)]),
            row("billing", selected: true)
        ]
        #expect(BackupScopeModel.scopes(in: rows).map(\.database) == ["billing"])
    }

    /// Ticking a mixed database means "all of it", which is the state a user reaches by unticking
    /// a few tables and then changing their mind.
    @Test("Toggling a mixed database ticks everything under it")
    func togglingMixedSelectsAll() {
        var rows = [row("sales", selected: true, objects: [("orders", true), ("carts", false)])]
        #expect(rows[0].isMixed)
        rows = BackupScopeModel.togglingDatabase("sales", in: rows)
        #expect(rows[0].isSelected)
        #expect(rows[0].objects.allSatisfy { $0.isSelected })
        #expect(!rows[0].isMixed)
    }

    @Test("Toggling a fully ticked database unticks everything under it")
    func togglingFullDeselectsAll() {
        var rows = [row("sales", selected: true, objects: [("orders", true), ("carts", true)])]
        rows = BackupScopeModel.togglingDatabase("sales", in: rows)
        #expect(!rows[0].isSelected)
        #expect(rows[0].objects.allSatisfy { !$0.isSelected })
        #expect(BackupScopeModel.scopes(in: rows).isEmpty)
    }

    /// Unticking the last object is a decision to leave the database out, not a decision to back it
    /// up empty, which would write a file that looks like a successful backup of nothing.
    @Test("Unticking the last object drops the database from the run")
    func lastObjectOffDropsTheDatabase() {
        var rows = [row("sales", selected: true, objects: [("orders", true)])]
        rows = BackupScopeModel.togglingObject("orders", in: "sales", rows: rows)
        #expect(!rows[0].isSelected)
        #expect(BackupScopeModel.scopes(in: rows).isEmpty)
    }

    @Test("Ticking an object again brings the database back carrying only that object")
    func tickingAnObjectRestoresTheDatabase() {
        var rows = [row("sales", selected: false, objects: [("orders", false), ("carts", false)])]
        rows = BackupScopeModel.togglingObject("carts", in: "sales", rows: rows)
        #expect(rows[0].isSelected)
        let scopes = BackupScopeModel.scopes(in: rows)
        #expect(scopes[0].scope.objects.map(\.name) == ["carts"])
    }

    @Test("The footer counts files for a run and objects for a narrowed one")
    func summaryText() {
        let whole = [row("sales", selected: true)]
        #expect(BackupScopeModel.summary(for: whole, objectScope: .tables(caveat: nil)) == "Writes 1 file.")

        let none = [row("sales", selected: false)]
        #expect(BackupScopeModel.summary(for: none, objectScope: .tables(caveat: nil)) == "Nothing selected.")

        let many = [row("sales", selected: true), row("billing", selected: true)]
        #expect(
            BackupScopeModel.summary(for: many, objectScope: .tables(caveat: nil))
                == "Writes 2 files, one for each database."
        )

        let narrowed = [row("sales", selected: true, objects: [("orders", true), ("carts", false)])]
        #expect(
            BackupScopeModel.summary(for: narrowed, objectScope: .tables(caveat: nil))
                == "Writes 1 file with 1 of 2 tables."
        )
    }

    /// A MongoDB row that says "42 tables" is wrong about the only thing it is there to say.
    /// A SQLite connection identifies its database by the file's whole path, so the tree shows the
    /// file's stem while the scope keeps the path the metadata read and the dump tool both need.
    @Test("A display name never replaces the database's identity")
    func displayNameIsSeparateFromIdentity() {
        var row = row("/Users/me/Chinook.sqlite", selected: true)
        row.displayName = "Chinook"
        let scopes = BackupScopeModel.scopes(in: [row])
        #expect(scopes[0].database == "/Users/me/Chinook.sqlite")
        #expect(scopes[0].label == "Chinook")
    }

    @Test("An engine that names its databases shows the name it gave")
    func labelFallsBackToTheName() {
        let scopes = BackupScopeModel.scopes(in: [row("sales", selected: true)])
        #expect(scopes[0].database == "sales")
        #expect(scopes[0].label == "sales")
    }

    @Test("The summary counts collections on MongoDB")
    func summaryUsesTheEngineNoun() {
        let narrowed = [
            row("sales", selected: true, objects: [("orders", true), ("carts", true), ("users", false)])
        ]
        #expect(
            BackupScopeModel.summary(for: narrowed, objectScope: .collections)
                == "Writes 1 file with 2 of 3 collections."
        )
    }
}
