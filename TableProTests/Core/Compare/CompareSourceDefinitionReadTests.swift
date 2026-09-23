//
//  CompareSourceDefinitionReadTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class CompareSourceDefinitionReadTests: XCTestCase {
    private let endpointName = "Reporting / shop"

    private func trigger(
        _ name: String,
        table: String = "orders",
        statement: String = "SET NEW.n = 1",
        definition: String? = nil
    ) -> PluginTriggerInfo {
        PluginTriggerInfo(
            name: name, table: table, schema: "shop", timing: "BEFORE", event: "INSERT",
            statement: statement, definition: definition
        )
    }

    // MARK: - Views

    func testAViewTheDriverRefusesCarriesTheDriversReason() async throws {
        let driver = SourceDefinitionStubDriver()
        let refusal = PluginObjectSourceError.insufficientPrivilege("recent")
        driver.viewDefinitions = ["recent": .failure(refusal), "totals": .failure(refusal)]

        let reads = try await CompareMetadataService.readViewDefinitions(
            [
                PluginTableInfo(name: "recent", type: "VIEW", schema: "shop", comment: nil),
                PluginTableInfo(name: "totals", type: "MATERIALIZED VIEW", schema: "shop", comment: nil)
            ],
            schema: "shop",
            using: driver
        )

        XCTAssertEqual(reads.map(\.failure), [refusal.errorDescription, refusal.errorDescription])
        XCTAssertEqual(reads.map(\.source), ["", ""])
        XCTAssertEqual(reads.map(\.kind), [.view, .materializedView])
    }

    func testAReadableViewKeepsItsDefinition() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = ["recent": .success("CREATE VIEW recent AS SELECT 1")]

        let reads = try await CompareMetadataService.readViewDefinitions(
            [PluginTableInfo(name: "recent", type: "VIEW", schema: "shop", comment: nil)],
            schema: "shop",
            using: driver
        )

        XCTAssertNil(reads.first?.failure)
        XCTAssertEqual(reads.first?.source, "CREATE VIEW recent AS SELECT 1")
    }

    func testACancelledViewReadIsNotAFailure() async {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = ["recent": .failure(CancellationError())]

        do {
            _ = try await CompareMetadataService.readViewDefinitions(
                [PluginTableInfo(name: "recent", type: "VIEW", schema: "shop", comment: nil)],
                schema: "shop",
                using: driver
            )
            XCTFail("a cancelled read must not become an unreadable object")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Routines

    func testARoutineIsReadThroughItsDDLEvenWhenTheListingCarriesABody() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.routines = .success([
            PluginRoutineInfo(name: "add", kind: .function, schema: "main", argumentSignature: "(a, b)", definition: "(a + b)")
        ])
        driver.routineDDL = ["add": .success("CREATE OR REPLACE MACRO main.add(a, b) AS (a + b);")]

        let reads = try await CompareMetadataService.readRoutineDefinitions(
            schema: "main", endpointName: endpointName, using: driver
        )

        XCTAssertEqual(reads.map(\.source), ["CREATE OR REPLACE MACRO main.add(a, b) AS (a + b);"])
        XCTAssertTrue(driver.recordedCalls.contains("fetchRoutineDDL:add"))
    }

    func testARoutineWhoseDDLCannotBeReadCarriesTheReason() async throws {
        let driver = SourceDefinitionStubDriver()
        let refusal = PluginObjectSourceError.insufficientPrivilege("p")
        driver.routines = .success([PluginRoutineInfo(name: "p", kind: .procedure, schema: "shop")])
        driver.routineDDL = ["p": .failure(refusal)]

        let reads = try await CompareMetadataService.readRoutineDefinitions(
            schema: "shop", endpointName: endpointName, using: driver
        )

        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.kind, .procedure)
        XCTAssertEqual(reads.first?.failure, refusal.errorDescription)
        XCTAssertEqual(reads.first?.source, "")
    }

    func testARoutineListingThatFailsStopsTheRead() async {
        let driver = SourceDefinitionStubDriver()
        driver.routines = .failure(DefinitionReadStubError(message: "Access denied to information_schema"))

        do {
            _ = try await CompareMetadataService.readRoutineDefinitions(
                schema: "shop", endpointName: endpointName, using: driver
            )
            XCTFail("an unlisted scope must not read as a scope with no routines")
        } catch {
            guard case CompareSyncError.readFailed(let message) = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
            XCTAssertTrue(message.contains(endpointName), message)
            XCTAssertTrue(message.contains("Access denied to information_schema"), message)
        }
    }

    // MARK: - Triggers

    func testATriggerWithoutADefinitionIsReadThroughItsDDLAndNeverItsStatement() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.wholeSchemaTriggers = .success([
            trigger("stamped"),
            trigger("hidden")
        ])
        driver.triggerDDL = [
            "stamped": .success("CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1"),
            "hidden": .failure(PluginObjectSourceError.insufficientPrivilege("hidden"))
        ]

        let reads = try await CompareMetadataService.readTriggerDefinitions(
            tables: ["orders"], schema: "shop", endpointName: endpointName, using: driver
        )

        XCTAssertEqual(reads.map(\.name), ["stamped", "hidden"])
        XCTAssertEqual(reads[0].source, "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1")
        XCTAssertNil(reads[0].failure)
        XCTAssertEqual(reads[1].source, "")
        XCTAssertEqual(reads[1].failure, PluginObjectSourceError.insufficientPrivilege("hidden").errorDescription)
        XCTAssertEqual(reads.map(\.signature), ["orders", "orders"])
    }

    func testATriggerWithADefinitionIsNotReadAgain() async throws {
        let driver = SourceDefinitionStubDriver()
        let definition = "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1"
        driver.wholeSchemaTriggers = .success([trigger("stamped", definition: definition)])

        let reads = try await CompareMetadataService.readTriggerDefinitions(
            tables: ["orders"], schema: "shop", endpointName: endpointName, using: driver
        )

        XCTAssertEqual(reads.map(\.source), [definition])
        XCTAssertFalse(driver.recordedCalls.contains("fetchTriggerDDL:stamped"))
    }

    func testAPerTableTriggerListingThatFailsStopsTheRead() async {
        let driver = SourceDefinitionStubDriver()
        driver.tableTriggers = [
            "customers": .success([]),
            "orders": .failure(DefinitionReadStubError(message: "TRIGGER command denied"))
        ]

        do {
            _ = try await CompareMetadataService.readTriggerDefinitions(
                tables: ["customers", "orders"], schema: "shop", endpointName: endpointName, using: driver
            )
            XCTFail("a table whose triggers could not be listed must not read as a table with none")
        } catch {
            guard case CompareSyncError.readFailed(let message) = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("orders"), message)
            XCTAssertTrue(message.contains(endpointName), message)
            XCTAssertTrue(message.contains("TRIGGER command denied"), message)
        }
    }

    func testAFailedWholeSchemaTriggerReadFallsBackPerTable() async throws {
        let driver = SourceDefinitionStubDriver()
        let definition = "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1"
        driver.wholeSchemaTriggers = .failure(DefinitionReadStubError(message: "bulk read refused"))
        driver.tableTriggers = ["orders": .success([trigger("stamped", definition: definition)])]

        let reads = try await CompareMetadataService.readTriggerDefinitions(
            tables: ["orders"], schema: "shop", endpointName: endpointName, using: driver
        )

        XCTAssertEqual(reads.map(\.source), [definition])
        XCTAssertTrue(driver.recordedCalls.contains("fetchTriggers:orders"))
    }
}
