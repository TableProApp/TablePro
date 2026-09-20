//
//  SourceObjectDiffEngineTests.swift
//  TableProTests
//
//  Views, procedures, functions and triggers have no parsed structure to compare: their body IS
//  the definition. What the engine has to get right is the matching, so an overloaded routine is
//  not confused with its sibling, and the normalising, so a formatting difference is not reported
//  as a real one.
//

@testable import TablePro
import XCTest

final class SourceObjectDiffEngineTests: XCTestCase {
    private func read(
        _ name: String,
        kind: CompareObjectKind = .function,
        schema: String? = "public",
        signature: String? = nil,
        source: String
    ) -> RoutineSourceRead {
        RoutineSourceRead(name: name, kind: kind, schema: schema, signature: signature, source: source)
    }

    private func engine(
        _ options: StructureCompareOptions = .default,
        databaseType: DatabaseType = .postgresql
    ) -> SourceObjectDiffEngine {
        SourceObjectDiffEngine(options: options, sourceDatabaseType: databaseType, targetDatabaseType: databaseType)
    }

    private func status(
        of source: String,
        against target: String,
        on databaseType: DatabaseType,
        options: StructureCompareOptions = .default
    ) -> TableDiffStatus? {
        engine(options, databaseType: databaseType).compare(
            source: [read("audit", source: source)],
            target: [read("audit", source: target)]
        ).first?.status
    }

    // MARK: - Status

    func testAnObjectOnlyOnTheSourceIsCreated() {
        let results = engine().compare(
            source: [read("audit", source: "BEGIN END")],
            target: []
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .onlyInSource)
        XCTAssertEqual(results[0].suggestedAction, .create)
    }

    func testAnObjectOnlyOnTheTargetIsDropped() {
        let results = engine().compare(
            source: [],
            target: [read("stale", source: "BEGIN END")]
        )

        XCTAssertEqual(results[0].status, .onlyInTarget)
        XCTAssertEqual(results[0].suggestedAction, .drop)
    }

    func testAMatchingDefinitionIsIdentical() {
        let results = engine().compare(
            source: [read("audit", source: "BEGIN\n  SELECT 1;\nEND")],
            target: [read("audit", source: "BEGIN\n  SELECT 1;\nEND")]
        )

        XCTAssertEqual(results[0].status, .identical)
        XCTAssertEqual(results[0].suggestedAction, .skip)
    }

    func testADifferentDefinitionIsAlter() {
        let results = engine().compare(
            source: [read("audit", source: "BEGIN SELECT 1; END")],
            target: [read("audit", source: "BEGIN SELECT 2; END")]
        )

        XCTAssertEqual(results[0].status, .differs)
        XCTAssertEqual(results[0].suggestedAction, .alter)
        XCTAssertFalse(results[0].sourceDefinition.isEmpty)
        XCTAssertFalse(results[0].targetDefinition.isEmpty)
    }

    // MARK: - Normalising

    func testTrailingSemicolonsAndLineEndingsAreNotADifference() {
        let results = engine().compare(
            source: [read("audit", source: "BEGIN SELECT 1; END;")],
            target: [read("audit", source: "BEGIN SELECT 1; END\r\n")]
        )

        XCTAssertEqual(results[0].status, .identical)
    }

    /// Measured on Oracle 23ai: a procedure sent without the `;` after its END is stored INVALID, with it VALID.
    func testAnOracleUnitWithoutItsOwnSemicolonIsADifferentObject() {
        let valid = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL;\nEND;"
        let invalid = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL;\nEND"

        XCTAssertEqual(status(of: valid, against: invalid, on: .oracle), .differs)
        XCTAssertEqual(status(of: valid, against: valid + "\n", on: .oracle), .identical)
    }

    /// Folding whitespace first turned the comment's newline into a space, and the comment then ran to the end of
    /// the text: a body that differed after it compared equal.
    func testALineCommentCannotHideTheRestOfTheBody() {
        let source = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL; -- keep\nEND;"
        let target = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL; -- keep\nEND"

        XCTAssertEqual(status(of: source, against: target, on: .oracle), .differs)
    }

    func testAWhenClauseOrADisabledStateIsADifference() {
        let plain = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"
        let guarded = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nWHEN (NEW.id > 0)\nBEGIN NULL; END;"
        let disabled = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nDISABLE\nBEGIN NULL; END;"

        XCTAssertEqual(status(of: plain, against: guarded, on: .oracle), .differs)
        XCTAssertEqual(status(of: plain, against: disabled, on: .oracle), .differs)
    }

    /// An engine the app has no grammar for accepts a definition with or without its trailing `;`.
    func testATrailingSemicolonIsNoDifferenceWhereTheGrammarIsNotTracked() {
        XCTAssertEqual(
            status(of: "CREATE VIEW audit AS SELECT 1;", against: "CREATE VIEW audit AS SELECT 1", on: .mssql),
            .identical
        )
    }

    func testWhitespaceIsADifferenceUntilItIsIgnored() {
        let source = [read("audit", source: "BEGIN\n    SELECT 1;\nEND")]
        let target = [read("audit", source: "BEGIN SELECT 1; END")]

        XCTAssertEqual(engine(strict()).compare(source: source, target: target)[0].status, .differs)

        var lenient = StructureCompareOptions.default
        lenient.ignoreWhitespaceInText = true
        XCTAssertEqual(engine(lenient).compare(source: source, target: target)[0].status, .identical)
    }

    func testIdentifierCaseIsADifferenceUntilItIsIgnored() {
        let source = [read("audit", source: "BEGIN SELECT 1; END")]
        let target = [read("audit", source: "begin select 1; end")]

        XCTAssertEqual(engine(strict()).compare(source: source, target: target)[0].status, .differs)

        var lenient = StructureCompareOptions.default
        lenient.ignoreIdentifierCase = true
        XCTAssertEqual(engine(lenient).compare(source: source, target: target)[0].status, .identical)
    }

    // MARK: - Matching

    /// PostgreSQL and Oracle both allow two routines to share a name, so the signature is part of
    /// the identity. Without it one overload is compared against the other.
    func testTwoOverloadsOfOneNameAreMatchedBySignature() {
        let results = engine().compare(
            source: [
                read("area", signature: "(integer)", source: "SELECT 1"),
                read("area", signature: "(geometry)", source: "SELECT 2")
            ],
            target: [
                read("area", signature: "(geometry)", source: "SELECT 2")
            ]
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { $0.status == .identical }.count, 1)
        XCTAssertEqual(results.filter { $0.status == .onlyInSource }.count, 1)
    }

    func testTwoKindsSharingOneNameAreNotMatched() {
        let results = engine().compare(
            source: [read("audit", kind: .function, source: "SELECT 1")],
            target: [read("audit", kind: .procedure, source: "SELECT 1")]
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.status }), [.onlyInSource, .onlyInTarget])
    }

    func testTwoSchemasSharingOneNameAreNotMatched() {
        let results = engine().compare(
            source: [read("audit", schema: "public", source: "SELECT 1")],
            target: [read("audit", schema: "sales", source: "SELECT 1")]
        )

        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Missing definitions

    /// A driver that lists a routine but cannot return its body must not report it as identical to
    /// another routine whose body is also empty.
    func testAnObjectWithNoDefinitionCarriesANote() {
        let results = engine().compare(
            source: [read("audit", source: "")],
            target: []
        )

        XCTAssertFalse(results[0].notes.isEmpty)
    }

    private func strict() -> StructureCompareOptions {
        var options = StructureCompareOptions.default
        options.ignoreWhitespaceInText = false
        options.ignoreIdentifierCase = false
        return options
    }
}

final class SourceObjectHazardTests: XCTestCase {
    private let classifier = SyncSafetyClassifier()

    private func identity(_ kind: CompareObjectKind) -> CompareObjectIdentity {
        CompareObjectIdentity(kind: kind, schema: "public", name: "reporting")
    }

    /// A view holds no rows, so dropping one is recoverable from the source and only warns. A
    /// materialized view does hold rows, so it is refused like a table.
    func testDroppingAViewIsRefusedButDroppingAMaterializedViewAlsoWarnsAboutItsRows() {
        let view = classifier.hazards(forDropping: identity(.view), isReplacement: false)
        let materialized = classifier.hazards(forDropping: identity(.materializedView), isReplacement: false)

        XCTAssertTrue(view.contains { $0.severity == .refusedByDefault })
        XCTAssertTrue(materialized.contains { $0.severity == .refusedByDefault })
        XCTAssertGreaterThan(materialized.count, view.count)
    }

    /// A replace drops and recreates, so it warns about dependents rather than about losing the
    /// object: the object comes straight back.
    func testAReplacementWarnsAboutDependentsRatherThanBeingRefused() {
        let hazards = classifier.hazards(forDropping: identity(.function), isReplacement: true)

        XCTAssertFalse(hazards.contains { $0.severity == .refusedByDefault })
        XCTAssertTrue(hazards.contains { $0.severity == .warning })
    }
}
