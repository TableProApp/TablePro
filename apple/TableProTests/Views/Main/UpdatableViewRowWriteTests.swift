import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct UpdatableViewRowWriteTests {
        private func openedView(answer: PluginViewRowEditing?, keys: [String]) throws -> MainContentCoordinator {
            let coordinator = MainContentCoordinator(
                connection: TestFixtures.makeConnection(database: "shop", type: .postgresql),
                tabManager: QueryTabManager(),
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            coordinator.openTableTab(TableInfo(name: "v_orders", type: .view, rowCount: nil, schema: "public"))
            let index = try #require(coordinator.tabManager.selectedTabIndex)
            coordinator.tabManager.tabs[index].tableContext.isEditable = true
            coordinator.tabManager.tabs[index].tableContext.primaryKeyColumns = keys
            coordinator.tabManager.tabs[index].tableContext.viewRowEditing = answer
            coordinator.tabManager.tabs[index].display.resultsViewMode = .data
            coordinator.setActiveTableRows(
                TableRows.from(
                    queryRows: [[.text("1"), .text("Alice")]],
                    columns: ["order_id", "name"],
                    columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                    hasAuthoritativeSchema: true
                ),
                for: coordinator.tabManager.tabs[index].id
            )
            return coordinator
        }

        private func editable(_ operations: PluginViewWriteOperations) -> PluginViewRowEditing {
            .editable(TestFixtures.viewTarget(
                base: PluginViewBaseTable(schema: "public", name: "orders"),
                keys: ["order_id"],
                operations: operations,
                baseColumnNames: ["order_id": "id", "name": "name"]
            ))
        }

        private func configuration(_ coordinator: MainContentCoordinator) throws -> DataGridConfiguration {
            coordinator.gridConfiguration(for: try #require(coordinator.tabManager.selectedTab))
        }

        @Test("A view the driver has not answered for refuses edits and says so in the grid")
        func unansweredViewExplainsItself() throws {
            let coordinator = try openedView(answer: nil, keys: [])
            defer { coordinator.teardown() }

            #expect(!coordinator.canEditActiveResult)
            #expect(coordinator.activeResultEditRefusal == .view(nil))
            #expect(try configuration(coordinator).editRefusalMessage == ResultEditRefusal.view(nil).message)
        }

        @Test("A read-only view's reason reaches the grid of the table tab")
        func readOnlyViewReasonReachesTheGrid() throws {
            let coordinator = try openedView(answer: .readOnly(.keyNotExposed), keys: [])
            defer { coordinator.teardown() }

            #expect(!coordinator.canEditActiveResult)
            #expect(try configuration(coordinator).editRefusalMessage == ResultEditRefusal.view(.keyNotExposed).message)
        }

        @Test("A view that refuses inserts edits and deletes rows but offers no Add Row")
        func viewWithoutInsert() throws {
            let coordinator = try openedView(answer: editable([.update, .delete]), keys: ["order_id"])
            defer { coordinator.teardown() }

            #expect(coordinator.canEditActiveResult)
            #expect(!coordinator.canAddRow)
            let configuration = try configuration(coordinator)
            #expect(configuration.editRefusalMessage == nil)
            #expect(!configuration.commands.contains(.addRow))
            #expect(!configuration.commands.contains(.pasteRows))
            #expect(configuration.commands.contains(.deleteRows))
        }

        @Test("A view that refuses deletes offers Add Row but no Delete")
        func viewWithoutDelete() throws {
            let coordinator = try openedView(answer: editable([.update, .insert]), keys: ["order_id"])
            defer { coordinator.teardown() }

            #expect(coordinator.canAddRow)
            let configuration = try configuration(coordinator)
            #expect(configuration.commands.contains(.addRow))
            #expect(!configuration.commands.contains(.deleteRows))
            #expect(!configuration.commands.contains(.undoDelete))
        }

        @Test("An answer keyed on other columns than the tab holds refuses, as a stale one would")
        func staleKeysRefuse() throws {
            let coordinator = try openedView(answer: editable(.all), keys: ["id"])
            defer { coordinator.teardown() }

            #expect(!coordinator.canEditActiveResult)
            #expect(coordinator.activeResultEditRefusal == .view(nil))
        }

        @Test("A save through a view carries the view's table into the plan")
        func savePlanCarriesTheBaseTable() throws {
            let coordinator = try openedView(answer: editable(.all), keys: ["order_id"])
            defer { coordinator.teardown() }
            coordinator.changeManager.configureForTable(
                tableName: "v_orders",
                schemaName: "public",
                columns: ["order_id", "name"],
                primaryKeyColumns: ["order_id"],
                databaseType: .postgresql,
                generatedColumns: []
            )
            coordinator.changeManager.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name",
                oldValue: .text("Alice"), newValue: .text("Ada"),
                originalRow: [.text("1"), .text("Alice")]
            )

            let plan = try coordinator.buildDataWritePlan(
                pendingTruncates: [], pendingDeletes: [], tableOperationOptions: [:]
            )
            #expect(plan.viewTarget?.baseTable.name == "orders")
        }
    }
}
