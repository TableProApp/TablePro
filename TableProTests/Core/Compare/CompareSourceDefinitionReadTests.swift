//
//  CompareSourceDefinitionReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CompareSourceDefinitionReadTests {
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

    private func object(
        _ name: String,
        type: String = "VIEW",
        indexes: ObjectIndexRead? = nil
    ) -> TableStructureRead {
        TableStructureRead(
            table: PluginTableInfo(name: name, type: type, schema: "shop", comment: nil),
            columns: [], indexes: [], foreignKeys: [], metadata: nil, failure: nil, objectIndexes: indexes
        )
    }

    @Test
    func aViewTheDriverRefusesCarriesTheDriversReason() async throws {
        let driver = SourceDefinitionStubDriver()
        let refusal = PluginObjectSourceError.insufficientPrivilege("recent")
        driver.viewDefinitions = ["recent": .failure(refusal), "totals": .failure(refusal)]

        let reads = try await CompareMetadataService.readViewDefinitions(
            [object("recent"), object("totals", type: "MATERIALIZED VIEW")],
            schema: "shop",
            using: driver
        )

        #expect(reads.map(\.failure) == [refusal.errorDescription, refusal.errorDescription])
        #expect(reads.map(\.source) == ["", ""])
        #expect(reads.map(\.kind) == [.view, .materializedView])
    }

    @Test
    func aReadableViewKeepsItsDefinition() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = ["recent": .success("CREATE VIEW recent AS SELECT 1")]

        let reads = try await CompareMetadataService.readViewDefinitions(
            [object("recent")],
            schema: "shop",
            using: driver
        )

        #expect(reads.first?.failure == nil)
        #expect(reads.first?.source == "CREATE VIEW recent AS SELECT 1")
    }

    @Test
    func aMaterializedViewsIndexesTravelWithItsDefinition() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = [
            "totals": .success("CREATE MATERIALIZED VIEW shop.totals AS SELECT 1 AS id"),
            "denied": .success("CREATE MATERIALIZED VIEW shop.denied AS SELECT 1 AS id")
        ]

        let reads = try await CompareMetadataService.readViewDefinitions(
            [
                object("totals", type: "MATERIALIZED VIEW", indexes: .read([
                    PluginIndexInfo(name: "totals_id_idx", columns: ["id"], isUnique: true)
                ])),
                object("denied", type: "MATERIALIZED VIEW", indexes: .failed("permission denied")),
                object("recent")
            ],
            schema: "shop",
            using: driver
        )

        guard case .read(let indexes)? = reads.first?.indexes else {
            Issue.record("the indexes read with the view must reach its definition read")
            return
        }
        #expect(indexes.map(\.name) == ["totals_id_idx"])
        guard case .failed(let reason)? = reads.dropFirst().first?.indexes else {
            Issue.record("a failed index read must reach the definition read as a failure")
            return
        }
        #expect(reason == "permission denied")
        #expect(reads.last?.indexes == nil)
    }

    @Test
    func aCancelledViewReadIsNotAFailure() async {
        let driver = SourceDefinitionStubDriver()
        driver.viewDefinitions = ["recent": .failure(CancellationError())]

        do {
            _ = try await CompareMetadataService.readViewDefinitions(
                [object("recent")],
                schema: "shop",
                using: driver
            )
            Issue.record("a cancelled read must not become an unreadable object")
        } catch {
            #expect(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Routines

    @Test
    func aRoutineIsReadThroughItsDDLEvenWhenTheListingCarriesABody() async throws {
        let driver = SourceDefinitionStubDriver()
        driver.routines = .success([
            PluginRoutineInfo(name: "add", kind: .function, schema: "main", argumentSignature: "(a, b)", definition: "(a + b)")
        ])
        driver.routineDDL = ["add": .success("CREATE OR REPLACE MACRO main.add(a, b) AS (a + b);")]

        let reads = try await CompareMetadataService.readRoutineDefinitions(
            schema: "main", endpointName: endpointName, using: driver
        )

        #expect(reads.map(\.source) == ["CREATE OR REPLACE MACRO main.add(a, b) AS (a + b);"])
        #expect(driver.recordedCalls.contains("fetchRoutineDDL:add"))
    }

    @Test
    func aRoutineWhoseDDLCannotBeReadCarriesTheReason() async throws {
        let driver = SourceDefinitionStubDriver()
        let refusal = PluginObjectSourceError.insufficientPrivilege("p")
        driver.routines = .success([PluginRoutineInfo(name: "p", kind: .procedure, schema: "shop")])
        driver.routineDDL = ["p": .failure(refusal)]

        let reads = try await CompareMetadataService.readRoutineDefinitions(
            schema: "shop", endpointName: endpointName, using: driver
        )

        #expect(reads.count == 1)
        #expect(reads.first?.kind == .procedure)
        #expect(reads.first?.failure == refusal.errorDescription)
        #expect(reads.first?.source == "")
    }

    @Test
    func aRoutineListingThatFailsStopsTheRead() async {
        let driver = SourceDefinitionStubDriver()
        driver.routines = .failure(DefinitionReadStubError(message: "Access denied to information_schema"))

        do {
            _ = try await CompareMetadataService.readRoutineDefinitions(
                schema: "shop", endpointName: endpointName, using: driver
            )
            Issue.record("an unlisted scope must not read as a scope with no routines")
        } catch {
            guard case CompareSyncError.readFailed(let message) = error else {
                Issue.record("expected readFailed, got \(error)")
                return
            }
            #expect(message.contains(endpointName), Comment(rawValue: message))
            #expect(message.contains("Access denied to information_schema"), Comment(rawValue: message))
        }
    }

    // MARK: - Triggers

    @Test
    func aTriggerWithoutADefinitionIsReadThroughItsDDLAndNeverItsStatement() async throws {
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

        #expect(reads.map(\.name) == ["stamped", "hidden"])
        #expect(reads[0].source == "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1")
        #expect(reads[0].failure == nil)
        #expect(reads[1].source == "")
        #expect(reads[1].failure == PluginObjectSourceError.insufficientPrivilege("hidden").errorDescription)
        #expect(reads.map(\.signature) == ["orders", "orders"])
    }

    @Test
    func aTriggerWithADefinitionIsNotReadAgain() async throws {
        let driver = SourceDefinitionStubDriver()
        let definition = "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1"
        driver.wholeSchemaTriggers = .success([trigger("stamped", definition: definition)])

        let reads = try await CompareMetadataService.readTriggerDefinitions(
            tables: ["orders"], schema: "shop", endpointName: endpointName, using: driver
        )

        #expect(reads.map(\.source) == [definition])
        #expect(!driver.recordedCalls.contains("fetchTriggerDDL:stamped"))
    }

    @Test
    func aPerTableTriggerListingThatFailsStopsTheRead() async {
        let driver = SourceDefinitionStubDriver()
        driver.tableTriggers = [
            "customers": .success([]),
            "orders": .failure(DefinitionReadStubError(message: "TRIGGER command denied"))
        ]

        do {
            _ = try await CompareMetadataService.readTriggerDefinitions(
                tables: ["customers", "orders"], schema: "shop", endpointName: endpointName, using: driver
            )
            Issue.record("a table whose triggers could not be listed must not read as a table with none")
        } catch {
            guard case CompareSyncError.readFailed(let message) = error else {
                Issue.record("expected readFailed, got \(error)")
                return
            }
            #expect(message.contains("orders"), Comment(rawValue: message))
            #expect(message.contains(endpointName), Comment(rawValue: message))
            #expect(message.contains("TRIGGER command denied"), Comment(rawValue: message))
        }
    }

    @Test
    func aFailedWholeSchemaTriggerReadFallsBackPerTable() async throws {
        let driver = SourceDefinitionStubDriver()
        let definition = "CREATE TRIGGER stamped BEFORE INSERT ON orders FOR EACH ROW SET NEW.n = 1"
        driver.wholeSchemaTriggers = .failure(DefinitionReadStubError(message: "bulk read refused"))
        driver.tableTriggers = ["orders": .success([trigger("stamped", definition: definition)])]

        let reads = try await CompareMetadataService.readTriggerDefinitions(
            tables: ["orders"], schema: "shop", endpointName: endpointName, using: driver
        )

        #expect(reads.map(\.source) == [definition])
        #expect(driver.recordedCalls.contains("fetchTriggers:orders"))
    }
}
