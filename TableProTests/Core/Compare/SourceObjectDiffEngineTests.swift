//
//  SourceObjectDiffEngineTests.swift
//  TableProTests
//
//  Views, procedures, functions and triggers have no parsed structure to compare: their body IS
//  the definition. What the engine has to get right is the matching, so an overloaded routine is
//  not confused with its sibling, and the normalising, so a formatting difference is not reported
//  as a real one.
//

import Foundation
@testable import TablePro
import Testing

struct SourceObjectDiffEngineTests {
    private func read(
        _ name: String,
        kind: CompareObjectKind = .function,
        schema: String? = "public",
        signature: String? = nil,
        source: String,
        failure: String? = nil
    ) -> RoutineSourceRead {
        RoutineSourceRead(
            name: name, kind: kind, schema: schema, signature: signature, source: source, failure: failure
        )
    }

    private func engine(
        _ options: StructureCompareOptions = .default,
        databaseType: DatabaseType = .postgresql
    ) -> SourceObjectDiffEngine {
        SourceObjectDiffEngine(
            options: options, sourceDatabaseType: databaseType, targetDatabaseType: databaseType, targetIndexedKinds: []
        )
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

    @Test
    func anObjectOnlyOnTheSourceIsCreated() {
        let results = engine().compare(
            source: [read("audit", source: "CREATE FUNCTION audit() BEGIN END")],
            target: []
        )

        #expect(results.count == 1)
        #expect(results[0].status == .onlyInSource)
        #expect(results[0].suggestedAction == .create)
    }

    @Test
    func anObjectOnlyOnTheTargetIsDropped() {
        let results = engine().compare(
            source: [],
            target: [read("stale", source: "CREATE FUNCTION stale() BEGIN END")]
        )

        #expect(results[0].status == .onlyInTarget)
        #expect(results[0].suggestedAction == .drop)
    }

    @Test
    func aMatchingDefinitionIsIdentical() {
        let results = engine().compare(
            source: [read("audit", source: "CREATE FUNCTION audit()\nBEGIN\n  SELECT 1;\nEND")],
            target: [read("audit", source: "CREATE FUNCTION audit()\nBEGIN\n  SELECT 1;\nEND")]
        )

        #expect(results[0].status == .identical)
        #expect(results[0].suggestedAction == .skip)
    }

    @Test
    func aDifferentDefinitionIsAlter() {
        let results = engine().compare(
            source: [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 1; END")],
            target: [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 2; END")]
        )

        #expect(results[0].status == .differs)
        #expect(results[0].suggestedAction == .alter)
        #expect(!(results[0].sourceDefinition.isEmpty))
        #expect(!(results[0].targetDefinition.isEmpty))
    }

    // MARK: - Normalising

    @Test
    func trailingSemicolonsAndLineEndingsAreNotADifference() {
        let results = engine().compare(
            source: [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 1; END;")],
            target: [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 1; END\r\n")]
        )

        #expect(results[0].status == .identical)
    }

    /// Measured on Oracle 23ai: a procedure sent without the `;` after its END is stored INVALID, with it VALID.
    @Test
    func anOracleUnitWithoutItsOwnSemicolonIsADifferentObject() {
        let valid = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL;\nEND;"
        let invalid = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL;\nEND"

        #expect(status(of: valid, against: invalid, on: .oracle) == .differs)
        #expect(status(of: valid, against: valid + "\n", on: .oracle) == .identical)
    }

    /// Folding whitespace first turned the comment's newline into a space, and the comment then ran to the end of
    /// the text: a body that differed after it compared equal.
    @Test
    func aLineCommentCannotHideTheRestOfTheBody() {
        let source = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL; -- keep\nEND;"
        let target = "CREATE OR REPLACE PROCEDURE audit IS\nBEGIN\n  NULL; -- keep\nEND"

        #expect(status(of: source, against: target, on: .oracle) == .differs)
    }

    @Test
    func aWhenClauseOrADisabledStateIsADifference() {
        let plain = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"
        let guarded = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nWHEN (NEW.id > 0)\nBEGIN NULL; END;"
        let disabled = "CREATE OR REPLACE TRIGGER audit BEFORE INSERT ON t FOR EACH ROW\nDISABLE\nBEGIN NULL; END;"

        #expect(status(of: plain, against: guarded, on: .oracle) == .differs)
        #expect(status(of: plain, against: disabled, on: .oracle) == .differs)
    }

    /// An engine the app has no grammar for accepts a definition with or without its trailing `;`.
    @Test
    func aTrailingSemicolonIsNoDifferenceWhereTheGrammarIsNotTracked() {
        #expect(status(of: "CREATE VIEW audit AS SELECT 1;", against: "CREATE VIEW audit AS SELECT 1", on: .mssql) == .identical)
    }

    @Test
    func whitespaceIsADifferenceUntilItIsIgnored() {
        let source = [read("audit", source: "CREATE FUNCTION audit()\nBEGIN\n    SELECT 1;\nEND")]
        let target = [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 1; END")]

        #expect(engine(strict()).compare(source: source, target: target)[0].status == .differs)

        var lenient = StructureCompareOptions.default
        lenient.ignoreWhitespaceInText = true
        #expect(engine(lenient).compare(source: source, target: target)[0].status == .identical)
    }

    @Test
    func identifierCaseIsADifferenceUntilItIsIgnored() {
        let source = [read("audit", source: "CREATE FUNCTION audit() BEGIN SELECT 1; END")]
        let target = [read("audit", source: "create function audit() begin select 1; end")]

        #expect(engine(strict()).compare(source: source, target: target)[0].status == .differs)

        var lenient = StructureCompareOptions.default
        lenient.ignoreIdentifierCase = true
        #expect(engine(lenient).compare(source: source, target: target)[0].status == .identical)
    }

    // MARK: - Matching

    /// PostgreSQL and Oracle both allow two routines to share a name, so the signature is part of
    /// the identity. Without it one overload is compared against the other.
    @Test
    func twoOverloadsOfOneNameAreMatchedBySignature() {
        let results = engine().compare(
            source: [
                read("area", signature: "(integer)", source: "CREATE FUNCTION area(integer) BEGIN SELECT 1; END"),
                read("area", signature: "(geometry)", source: "CREATE FUNCTION area(geometry) BEGIN SELECT 2; END")
            ],
            target: [
                read("area", signature: "(geometry)", source: "CREATE FUNCTION area(geometry) BEGIN SELECT 2; END")
            ]
        )

        #expect(results.count == 2)
        #expect(results.filter { $0.status == .identical }.count == 1)
        #expect(results.filter { $0.status == .onlyInSource }.count == 1)
    }

    @Test
    func twoKindsSharingOneNameAreNotMatched() {
        let results = engine().compare(
            source: [read("audit", kind: .function, source: "CREATE FUNCTION audit() BEGIN END")],
            target: [read("audit", kind: .procedure, source: "CREATE PROCEDURE audit() BEGIN END")]
        )

        #expect(results.count == 2)
        #expect(Set(results.map { $0.status }) == [.onlyInSource, .onlyInTarget])
    }

    @Test
    func twoSchemasSharingOneNameAreNotMatched() {
        let results = engine().compare(
            source: [read("audit", schema: "public", source: "CREATE FUNCTION audit() BEGIN END")],
            target: [read("audit", schema: "sales", source: "CREATE FUNCTION audit() BEGIN END")]
        )

        #expect(results.count == 2)
    }

    // MARK: - Unreadable definitions

    @Test
    func aSourceWhoseReadFailedIsNotComparedAgainstAReadableTarget() {
        let denied = "SHOW VIEW command denied to user 'reader'@'%' for table 'v'"
        let results = engine(databaseType: .mysql).compare(
            source: [read("v", kind: .view, schema: nil, source: "", failure: denied)],
            target: [read("v", kind: .view, schema: nil, source: "CREATE VIEW v AS SELECT 1")]
        )

        #expect(results.count == 1)
        #expect(results[0].comparisonError == SourceDefinitionDefect.unreadable(denied).reason(on: .source))
        #expect(results[0].suggestedAction == .skip)
        #expect(results[0].availableActions == [.skip])
        #expect(results[0].sourceDefinition == [])
        #expect(results[0].targetDefinition == ["CREATE VIEW v AS SELECT 1"])
    }

    @Test
    func twoFailedReadsOfOneObjectAreNotIdentical() {
        let results = engine().compare(
            source: [read("v", kind: .view, source: "", failure: "denied")],
            target: [read("v", kind: .view, source: "", failure: "denied")]
        )

        #expect(results.count == 1)
        #expect(results[0].status != .identical)
        #expect(!(results[0].isComparable))
    }

    @Test
    func anUnreadableObjectOnlyOnTheSourceIsNeverCreated() {
        let results = engine().compare(
            source: [read("audit", source: "", failure: "permission denied")],
            target: []
        )

        #expect(results[0].comparisonError == SourceDefinitionDefect.unreadable("permission denied").reason(on: .source))
        #expect(results[0].suggestedAction == .skip)
        #expect(results[0].availableActions == [.skip])
    }

    @Test
    func anUnreadableObjectOnlyOnTheTargetNamesTheTargetAndIsNeverDropped() {
        let results = engine().compare(
            source: [],
            target: [read("stale", source: "", failure: "permission denied")]
        )

        #expect(results[0].comparisonError == SourceDefinitionDefect.unreadable("permission denied").reason(on: .target))
        #expect(results[0].availableActions == [.skip])
    }

    @Test
    func aDefinitionWithNothingToRunIsUnreadable() {
        for blank in ["", "   \n\t", "-- nothing here", "/* nothing */", "# nothing"] {
            let results = engine(databaseType: .mysql).compare(
                source: [read("audit", source: blank)],
                target: [read("audit", source: "CREATE FUNCTION audit() RETURNS INT RETURN 1")]
            )

            #expect(results[0].comparisonError == SourceDefinitionDefect.empty.reason(on: .source), Comment(rawValue: blank))
            #expect(results[0].availableActions == [.skip], Comment(rawValue: blank))
        }
    }

    @Test
    func aBodyThatIsNotACreateStatementIsUnreadable() {
        for body in ["(a + b)", "SELECT 1 AS x"] {
            let results = engine(databaseType: .duckdb).compare(
                source: [read("add", source: body)],
                target: []
            )

            #expect(results[0].comparisonError == SourceDefinitionDefect.notACreateStatement.reason(on: .source), Comment(rawValue: body))
            #expect(results[0].availableActions == [.skip], Comment(rawValue: body))
            #expect(results[0].sourceDefinition == [body], Comment(rawValue: body))
        }
    }

    @Test
    func aLeadingCommentDoesNotHideTheCreate() {
        let definition = "-- Author: ops\n/* audit */\nCREATE PROCEDURE dbo.audit AS SET NOCOUNT ON; SELECT 1;"

        let results = engine(databaseType: .mssql).compare(
            source: [read("audit", schema: "dbo", source: definition)],
            target: [read("audit", schema: "dbo", source: definition)]
        )

        #expect(results[0].comparisonError == nil)
        #expect(results[0].status == .identical)
    }

    @Test
    func eachSideIsReadInItsOwnEnginesGrammar() {
        let mysqlDefinition = "# reporting view\nCREATE VIEW v AS SELECT 1"
        let postgresDefinition = "CREATE VIEW v AS SELECT 1"

        let fromMySQL = SourceObjectDiffEngine(
            sourceDatabaseType: .mysql, targetDatabaseType: .postgresql, targetIndexedKinds: []
        ).compare(
            source: [read("v", kind: .view, schema: nil, source: mysqlDefinition)],
            target: [read("v", kind: .view, schema: nil, source: postgresDefinition)]
        )
        let intoMySQL = SourceObjectDiffEngine(
            sourceDatabaseType: .postgresql, targetDatabaseType: .mysql, targetIndexedKinds: []
        ).compare(
            source: [read("v", kind: .view, schema: nil, source: postgresDefinition)],
            target: [read("v", kind: .view, schema: nil, source: mysqlDefinition)]
        )

        #expect(fromMySQL[0].comparisonError == nil)
        #expect(intoMySQL[0].comparisonError == nil)
    }

    @Test
    func aSQLServerModuleStoredAfterAlterOrCreateOrAlterIsReadable() {
        let altered = "/* comment */  CREATE PROCEDURE Test1A  AS  SELECT 3;"
        let createdOrAltered = "CrEaTe /*Y*/ PROCEDURE Test1B AS SELECT 2;"

        let results = engine(databaseType: .mssql).compare(
            source: [
                read("Test1A", kind: .procedure, schema: "dbo", source: altered),
                read("Test1B", kind: .procedure, schema: "dbo", source: createdOrAltered)
            ],
            target: []
        )

        #expect(results.map(\.comparisonError) == [nil, nil])
        #expect(results.map(\.suggestedAction) == [.create, .create])
    }

    @Test
    func anUnreadableObjectIsNeitherADifferenceNorSelectable() {
        let report = CompareReport(results: engine().compare(
            source: [read("v", kind: .view, source: "", failure: "denied")],
            target: [read("v", kind: .view, source: "CREATE VIEW v AS SELECT 1")]
        ))

        #expect(report.uncomparable.count == 1)
        #expect(report.comparable.isEmpty)
        #expect(report.differenceCount == 0)
    }

    private func strict() -> StructureCompareOptions {
        var options = StructureCompareOptions.default
        options.ignoreWhitespaceInText = false
        options.ignoreIdentifierCase = false
        return options
    }
}

struct SourceObjectHazardTests {
    private let classifier = SyncSafetyClassifier()

    private func identity(_ kind: CompareObjectKind) -> CompareObjectIdentity {
        CompareObjectIdentity(kind: kind, schema: "public", name: "reporting")
    }

    /// A view holds no rows, so dropping one is recoverable from the source and only warns. A
    /// materialized view does hold rows, so it is refused like a table.
    @Test
    func droppingAViewIsRefusedButDroppingAMaterializedViewAlsoWarnsAboutItsRows() {
        let view = classifier.hazards(forDropping: identity(.view), isReplacement: false)
        let materialized = classifier.hazards(forDropping: identity(.materializedView), isReplacement: false)

        #expect(view.contains { $0.severity == .refusedByDefault })
        #expect(materialized.contains { $0.severity == .refusedByDefault })
        #expect(materialized.count > view.count)
    }

    /// A replace drops and recreates, so it warns about dependents rather than about losing the
    /// object: the object comes straight back.
    @Test
    func aReplacementWarnsAboutDependentsRatherThanBeingRefused() {
        let hazards = classifier.hazards(forDropping: identity(.function), isReplacement: true)

        #expect(!(hazards.contains { $0.severity == .refusedByDefault }))
        #expect(hazards.contains { $0.severity == .warning })
    }
}
