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

    private func engine(_ options: StructureCompareOptions = .default) -> SourceObjectDiffEngine {
        SourceObjectDiffEngine(options: options)
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
