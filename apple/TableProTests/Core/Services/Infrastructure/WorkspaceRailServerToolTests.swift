//
//  WorkspaceRailServerToolTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct WorkspaceRailServerToolTests {
    private static let dashboard = String(localized: "Server Dashboard")
    private static let insights = String(localized: "Query Insights")

    private static func context(
        isConnected: Bool = true,
        isAgentMode: Bool = false,
        supportsServerDashboard: Bool = true
    ) -> MenuValidationContext {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = isConnected
        context.isAgentMode = isAgentMode
        context.supportsServerDashboard = supportsServerDashboard
        return context
    }

    private static func offered(_ context: MenuValidationContext) -> [String] {
        WorkspaceRailViewController.serverTools(offeredWith: context).map(\.title)
    }

    @Test("A browsing connection gets both tools in the Database menu's order")
    func browsingOffersBoth() {
        #expect(Self.offered(Self.context()) == [Self.dashboard, Self.insights])
    }

    @Test("An engine without a dashboard gets Query Insights only")
    func dashboardFollowsTheEngine() {
        #expect(Self.offered(Self.context(supportsServerDashboard: false)) == [Self.insights])
    }

    @Test("Agent mode and a connection that is not live get neither")
    func neitherWithoutBrowseContent() {
        #expect(Self.offered(Self.context(isAgentMode: true)).isEmpty)
        #expect(Self.offered(Self.context(isConnected: false)).isEmpty)
    }

    @Test("Each tool runs the menu bar's own command")
    func toolsRunTheMenuBarCommands() {
        let commands = WorkspaceRailViewController.serverTools(offeredWith: Self.context()).map(\.command)
        #expect(commands == [
            #selector(MainSplitViewController.showServerDashboard(_:)),
            #selector(MainSplitViewController.showQueryInsights(_:)),
        ])
    }

    private static func entry() -> WorkspaceRailEntry {
        WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: UUID(), container: ""),
            connection: TestFixtures.makeConnection(name: "Primary", type: .postgresql),
            status: .connected
        )
    }

    private static func layout(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test("The tools sit in their own group, targeted at the rail and naming the row, with no chord")
    func toolItemsAreGroupedAndNameTheRow() {
        let rail = WorkspaceRailViewController()
        let entry = Self.entry()
        let tools = WorkspaceRailViewController.serverTools(offeredWith: Self.context())
        let menu = NSMenu()

        rail.populate(menu, for: entry, serverTools: tools)

        let close = String(format: String(localized: "Close Connection “%@”"), entry.connection.name)
        #expect(Self.layout(of: menu) == [
            Self.dashboard, Self.insights, "---", String(localized: "Disconnect"), "---", close,
        ])
        for tool in tools {
            let item = menu.items.first { $0.title == tool.title }
            #expect(item?.action == tool.railAction)
            #expect(item?.target === rail)
            #expect(item?.representedObject as? WorkspaceID == entry.workspace)
            #expect(item?.keyEquivalent.isEmpty == true, "\(tool.title) draws a chord the row cannot run")
        }
    }

    @Test("No tools leaves no empty group behind")
    func noToolsNoSeparator() {
        let entry = Self.entry()
        let menu = NSMenu()

        WorkspaceRailViewController().populate(menu, for: entry, serverTools: [])

        let close = String(format: String(localized: "Close Connection “%@”"), entry.connection.name)
        #expect(Self.layout(of: menu) == [String(localized: "Disconnect"), "---", close])
    }
}
