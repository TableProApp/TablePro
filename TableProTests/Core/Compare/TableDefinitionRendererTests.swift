//
//  TableDefinitionRendererTests.swift
//  TableProTests
//

import Foundation
import XCTest

@testable import TablePro

final class TableDefinitionRendererTests: XCTestCase {
    private func column(
        _ name: String,
        _ dataType: String = "int",
        nullable: Bool = true,
        primaryKey: Bool = false,
        comment: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: dataType, isNullable: nullable, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: comment, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: primaryKey
        )
    }

    private func index(_ name: String, columns: [String], unique: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: unique,
            isPrimary: false, comment: nil, columnPrefixes: [:], whereClause: nil
        )
    }

    func testRendersColumnsPrimaryKeyAndIndexes() {
        let snapshot = TableStructureSnapshot(
            name: "users",
            columns: [column("id", "int", nullable: false, primaryKey: true), column("email", "varchar(255)")],
            indexes: [index("idx_email", columns: ["email"], unique: true)]
        )

        let lines = TableDefinitionRenderer.lines(for: snapshot)

        XCTAssertEqual(lines.first, "TABLE users")
        XCTAssertTrue(lines.contains { $0.contains("COLUMN id int NOT NULL") })
        XCTAssertTrue(lines.contains { $0.contains("COLUMN email varchar(255) NULL") })
        XCTAssertTrue(lines.contains("  PRIMARY KEY (id)"))
        XCTAssertTrue(lines.contains { $0.contains("UNIQUE INDEX idx_email (email)") })
    }

    func testRenderingIsDeterministicRegardlessOfIndexOrder() {
        let first = TableStructureSnapshot(
            name: "t",
            columns: [column("id")],
            indexes: [index("b_idx", columns: ["a"]), index("a_idx", columns: ["b"])]
        )
        let second = TableStructureSnapshot(
            name: "t",
            columns: [column("id")],
            indexes: [index("a_idx", columns: ["b"]), index("b_idx", columns: ["a"])]
        )

        XCTAssertEqual(
            TableDefinitionRenderer.lines(for: first),
            TableDefinitionRenderer.lines(for: second),
            "index declaration order must not change the rendered definition"
        )
    }

    func testIdenticalSnapshotsRenderIdenticallySoTheDiffIsEmpty() {
        let snapshot = TableStructureSnapshot(
            name: "users",
            columns: [column("id", nullable: false), column("name", "varchar(20)", comment: "hi")],
            indexes: [index("i", columns: ["name"])]
        )

        let pairs = DiffComputer.computeSplit(
            before: TableDefinitionRenderer.lines(for: snapshot),
            after: TableDefinitionRenderer.lines(for: snapshot)
        )

        XCTAssertTrue(pairs.allSatisfy { $0.kind == .unchanged })
    }

    func testChangedColumnTypeProducesAChangedLine() {
        let target = TableStructureSnapshot(name: "t", columns: [column("id", "int")])
        let source = TableStructureSnapshot(name: "t", columns: [column("id", "bigint")])

        let pairs = DiffComputer.computeSplit(
            before: TableDefinitionRenderer.lines(for: target),
            after: TableDefinitionRenderer.lines(for: source)
        )

        XCTAssertTrue(pairs.contains { $0.kind != .unchanged })
    }
}

@MainActor
final class CompareSyncProfileStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var storage: CompareSyncProfileStorage!
    private let suiteName = "CompareSyncProfileStorageTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        storage = CompareSyncProfileStorage(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        storage = nil
        super.tearDown()
    }

    private func scope(_ connectionId: UUID, database: String = "app", schema: String? = nil) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    private func profile(
        name: String,
        source: DatabaseScope,
        target: DatabaseScope,
        mode: CompareSyncMode = .structure
    ) -> CompareSyncProfile {
        CompareSyncProfile(
            name: name,
            source: source,
            target: target,
            mode: mode,
            structureOptions: .default,
            dataOptions: .default,
            selectedObjects: ["users"]
        )
    }

    func testSavedProfileRoundTrips() {
        let source = scope(UUID())
        let target = scope(UUID())
        storage.save(profile(name: "nightly", source: source, target: target))

        let loaded = storage.profiles(source: source, target: target, mode: .structure)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "nightly")
        XCTAssertEqual(loaded[0].selectedObjects, ["users"])
    }

    func testProfilesAreScopedToSourceTargetAndMode() {
        let source = scope(UUID())
        let target = scope(UUID())
        storage.save(profile(name: "structure", source: source, target: target, mode: .structure))
        storage.save(profile(name: "data", source: source, target: target, mode: .data))

        XCTAssertEqual(storage.profiles(source: source, target: target, mode: .structure).map(\.name), ["structure"])
        XCTAssertEqual(storage.profiles(source: source, target: target, mode: .data).map(\.name), ["data"])
        XCTAssertTrue(storage.profiles(source: target, target: source, mode: .structure).isEmpty)
    }

    /// Keying on the connection pair alone could not tell two databases on one server apart, so a
    /// comparison saved against staging came back for production.
    func testTwoDatabasesOnOneConnectionKeepSeparateProfiles() {
        let connectionId = UUID()
        let staging = scope(connectionId, database: "app_staging")
        let production = scope(connectionId, database: "app_prod")
        let target = scope(UUID())
        storage.save(profile(name: "staging", source: staging, target: target))
        storage.save(profile(name: "production", source: production, target: target))

        XCTAssertEqual(storage.profiles(source: staging, target: target, mode: .structure).map(\.name), ["staging"])
        XCTAssertEqual(
            storage.profiles(source: production, target: target, mode: .structure).map(\.name), ["production"]
        )
    }

    func testTwoSchemasInOneDatabaseKeepSeparateProfiles() {
        let connectionId = UUID()
        let publicSchema = scope(connectionId, schema: "public")
        let salesSchema = scope(connectionId, schema: "sales")
        let target = scope(UUID())
        storage.save(profile(name: "public", source: publicSchema, target: target))
        storage.save(profile(name: "sales", source: salesSchema, target: target))

        XCTAssertEqual(storage.profiles(source: publicSchema, target: target, mode: .structure).map(\.name), ["public"])
        XCTAssertEqual(storage.profiles(source: salesSchema, target: target, mode: .structure).map(\.name), ["sales"])
    }

    func testSavingSameProfileIdUpdatesRatherThanDuplicates() {
        let source = scope(UUID())
        let target = scope(UUID())
        var existing = profile(name: "first", source: source, target: target)
        storage.save(existing)
        existing.name = "renamed"
        storage.save(existing)

        let loaded = storage.profiles(source: source, target: target, mode: .structure)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "renamed")
    }

    func testDeleteRemovesOnlyThatProfile() {
        let source = scope(UUID())
        let target = scope(UUID())
        let keep = profile(name: "keep", source: source, target: target)
        let drop = profile(name: "drop", source: source, target: target)
        storage.save(keep)
        storage.save(drop)

        storage.delete(drop)

        XCTAssertEqual(storage.profiles(source: source, target: target, mode: .structure).map(\.name), ["keep"])
    }
}
