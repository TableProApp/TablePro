//
//  MCPWritePolicyMatrixTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

extension GlobalStateSuites {
    @MainActor
    struct MCPWritePolicyMatrixTests {
        private static let hiddenTab = "\(MCPToolErrorCode.notFound.rawValue): No open tab this client may reach has that id."
        private static let windowlessTab = "\(MCPToolErrorCode.notFound.rawValue): That tab no longer has a window."

        private struct Observation {
            // A protocol refusal, a `denied` tool error, or a tab list that hides the tab.
            let refused: Bool
            let succeeded: Bool
            let prompts: [WritePrompt]
            let received: [String]
            let session: ConnectionSession?
            let detail: String
            var unexpected = false
        }

        @Test("Every MCP tool that can write has a row in the matrix")
        func everyWritingToolHasARow() {
            let writing = MCPToolRegistry.allTools.map { type(of: $0) }.filter { toolType in
                let takesStatement = toolType.inputSchema["properties"]?["query"] != nil
                    && !MCPWritePath.queryArgumentsThatAreNotStatements.contains(toolType.name)
                return toolType.requiredScopes.contains(.toolsWrite) || takesStatement
            }
            let rows = Set(MCPWritePath.allCases.map(\.toolName))
            #expect(Set(writing.map { $0.name }) == rows)
        }

        @Test("An MCP write is refused, asks, or runs as the matrix says", arguments: MCPWritePath.allCases)
        func everyCell(path: MCPWritePath) async {
            var mismatches: [String] = []
            for cell in MCPWriteCell.all {
                mismatches += await check(path, cell)
            }
            #expect(mismatches.isEmpty, "\(path.toolName):\n\(mismatches.joined(separator: "\n"))")
        }

        private func check(_ path: MCPWritePath, _ cell: MCPWriteCell) async -> [String] {
            let expected = MCPWritePath.expected(path, cell)
            let approved = await call(path, cell, answer: .approveAll)
            var mismatches: [String] = []
            let label = "\(cell), expected \(expected)"
            if approved.unexpected {
                mismatches.append("\(label): \(approved.detail)")
            }

            guard case .runs(let prompts) = expected else {
                mismatches += refusalMismatches(path, approved, label: label)
                if approved.prompts.contains(.confirmation) || approved.prompts.contains(.authentication) {
                    mismatches.append("\(label): asked \(approved.prompts) before refusing")
                }
                return mismatches
            }

            if approved.refused {
                mismatches.append("\(label): refused (\(approved.detail))")
            }
            if approved.prompts != prompts {
                mismatches.append("\(label): asked \(approved.prompts)")
            }
            switch path.reach {
            case .statement:
                if !approved.succeeded {
                    mismatches.append("\(label): failed (\(approved.detail))")
                }
                if !approved.received.contains(where: { $0.contains(path.driverReceives) }) {
                    mismatches.append("\(label): the driver received \(approved.received)")
                }
            case .session:
                if !approved.succeeded || !path.changed(approved.session) {
                    mismatches.append("\(label): the session was not changed (\(approved.detail))")
                }
            case .window:
                if !approved.detail.hasPrefix("\(MCPToolErrorCode.notFound.rawValue):") {
                    mismatches.append("\(label): did not reach the tool's own lookup (\(approved.detail))")
                }
            case .tab:
                if approved.detail != Self.windowlessTab {
                    mismatches.append("\(label): did not reach the tab (\(approved.detail))")
                }
            }

            guard let first = prompts.first else { return mismatches }
            let declined = await call(path, cell, answer: .refuseAll)
            mismatches += refusalMismatches(path, declined, label: "\(label), first prompt declined")
            if declined.prompts != [first] {
                mismatches.append("\(label), first prompt declined: asked \(declined.prompts)")
            }
            return mismatches
        }

        private func refusalMismatches(_ path: MCPWritePath, _ observed: Observation, label: String) -> [String] {
            var mismatches: [String] = []
            if !observed.refused {
                mismatches.append("\(label): not refused (\(observed.detail))")
            }
            if !observed.received.isEmpty {
                mismatches.append("\(label): the driver received \(observed.received)")
            }
            let untouched = observed.session.map { $0.browseDatabase == nil && $0.browseSchema == nil } ?? false
            if path.reach == .session, !untouched {
                mismatches.append("\(label): the session was changed")
            }
            return mismatches
        }

        private func call(
            _ path: MCPWritePath,
            _ cell: MCPWriteCell,
            answer: WritePolicyPrompts.Answer
        ) async -> Observation {
            let prompts = WritePolicyPrompts(answer)
            let rig = WritePolicyRig(
                connection: WritePolicyRig.connection(
                    type: path.databaseType,
                    externalAccess: cell.externalAccess,
                    aiPolicy: cell.aiPolicy,
                    safeMode: cell.safeMode
                ),
                prompts: prompts,
                live: path.reach == .statement || path.reach == .session
            )
            defer { rig.tearDown() }
            let tabOwner = path.reach == .tab ? Self.coordinatorWithOneTab(for: rig.connection) : nil
            defer { tabOwner?.teardown() }

            let handler = ToolsCallHandler(services: MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            ))
            let params = MCPToolTestHarness.toolCallParams(
                name: path.toolName,
                arguments: path.arguments(
                    connectionId: rig.connection.id,
                    tabId: tabOwner?.tabManager.tabs.first?.id ?? UUID()
                )
            )
            let principal = MCPToolTestHarness.principal(scopes: cell.token.scopes)
            let context = MCPToolTestHarness.context(params: params, principal: principal)

            var refused: Bool
            var succeeded = false
            var detail: String
            var unexpected = false
            do {
                let result = try await handler.handle(params: params, context: context)
                detail = result.payload["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                let isError = result.payload["isError"]?.boolValue == true
                refused = isError && detail.hasPrefix("\(MCPToolErrorCode.denied.rawValue):")
                succeeded = !isError
            } catch let error as MCPProtocolError where error.code == JsonRpcErrorCode.forbidden {
                refused = true
                detail = error.message
            } catch {
                refused = false
                detail = "unexpected \(error)"
                unexpected = true
            }

            if path.reach == .tab, detail == Self.hiddenTab {
                refused = true
            }

            return Observation(
                refused: refused,
                succeeded: succeeded,
                prompts: prompts.prompts,
                received: rig.driver.received,
                session: DatabaseManager.shared.session(for: rig.connection.id),
                detail: detail,
                unexpected: unexpected
            )
        }

        private static func coordinatorWithOneTab(for connection: DatabaseConnection) -> MainContentCoordinator {
            let tabManager = QueryTabManager()
            let tab = QueryTab(title: "Matrix", query: "SELECT 1", tabType: .query)
            tabManager.tabs = [tab]
            tabManager.selectedTabId = tab.id
            let coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            coordinator.registerEagerly()
            return coordinator
        }
    }
}
