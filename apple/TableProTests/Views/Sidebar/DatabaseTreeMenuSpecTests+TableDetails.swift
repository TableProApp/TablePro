import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension DatabaseTreeMenuSpecTests {
    private func viewOptionEntries(_ sections: [DatabaseTreeMenuSection]) -> [SidebarMenuEntry<SidebarMenuCommand>] {
        sections.flatMap { $0.items }.compactMap { item -> SidebarMenuEntry<SidebarMenuCommand>? in
            guard case .command(let entry) = item else { return nil }
            return entry
        }
    }

    @Test("View Options lists Table Details right after Partitions, with its own state")
    func viewOptionsOfferTableDetails() {
        let sections = SidebarViewOptionsMenu.sections(
            showObjectIcons: true,
            showObjectComments: true,
            showSystemContainers: true,
            showPartitions: true,
            showTableDetails: false,
            rowSize: .matchSystem
        )
        let toggles = viewOptionEntries(Array(sections.prefix(1)))
        let commands = toggles.map { $0.command }
        let expected: [SidebarMenuCommand] = [
            .toggleObjectIcons, .toggleObjectComments, .toggleSystemContainers, .togglePartitions, .toggleTableDetails
        ]

        #expect(commands == expected)
        #expect(toggles.last?.title == String(localized: "Table Details"))
        #expect(toggles.last?.isOn == false)
    }

    @Test("The empty-area menu reads Table Details from its context")
    func viewOptionsReadTableDetailsFromTheContext() {
        var menuContext = context(clicked: nil)
        menuContext.showTableDetails = true
        let state = viewOptionEntries(SidebarViewOptionsMenu.sections(menuContext))
            .first { $0.command == .toggleTableDetails }?
            .isOn

        #expect(state == true)
    }

    @Test("A column, index, key or check offers Copy Name, then Show Structure for its table")
    func detailRowMenu() {
        let orders = tableRef("orders")
        let items: [TableDetailItem] = [
            .column(TestFixtures.makeColumnInfo(name: "total")),
            .index(IndexInfo(name: "orders_total_idx", columns: ["total"], isUnique: false, isPrimary: false, type: "BTREE")),
            .foreignKey(EditableForeignKeyDefinition.from(TestFixtures.makeForeignKeyInfo(name: "orders_user_fk"))),
            .check(CheckConstraintInfo(name: "total_positive", expression: "total > 0")),
        ]

        for item in items {
            let clicked = DatabaseTreeNode.Kind.tableDetail(DatabaseTreeTableDetailRef(table: orders, item: item))
            let sections = DatabaseTreeMenuSpec.sections(for: context(clicked: clicked))

            #expect(sections.count == 2, "\(item.name)")
            #expect(commands(sections) == [.copyText(item.name), .showStructure(orders)], "\(item.name)")
        }
    }

    @Test("A detail group row offers the sidebar's own menu, as a status row does")
    func detailGroupMenuIsTheBackgroundMenu() {
        let group = DatabaseTreeTableDetailGroupRef(table: tableRef("orders"), kind: .columns)

        let clicked = commands(DatabaseTreeMenuSpec.sections(for: context(clicked: .tableDetailGroup(group))))
        let background = commands(DatabaseTreeMenuSpec.sections(for: context(clicked: nil)))

        #expect(clicked == background)
    }

    @Test("A trigger under its table keeps the trigger menu, naming the table the driver left out")
    func triggerUnderTableMenu() {
        let bare = TriggerInfo(name: "orders_audit", timing: "AFTER", event: "INSERT", statement: "")
        let entries = TableDetailRows.entries(for: .triggers([bare]), table: tableRef("orders"))
        guard case .trigger(let ref) = entries.first?.row else {
            Issue.record("A trigger is not a trigger row")
            return
        }

        let menu = commands(DatabaseTreeMenuSpec.sections(for: context(clicked: .trigger(ref))))

        #expect(menu == [.copyText("orders_audit"), .copyText("orders"), .showObjectSource(ref.objectRef)])
    }
}

extension GlobalStateSuites {
    @MainActor
    struct TableDetailsViewOptionsTests {
        @Test(
            "Table Details in View Options starts off and flips the setting",
            .appSettings { $0.general.showTableDetails = false }
        )
        func viewOptionsEntryWritesTheSetting() throws {
            let found = SidebarViewOptionsMenu.currentSections()
                .flatMap { $0.items }
                .lazy
                .compactMap { item -> SidebarMenuEntry<SidebarMenuCommand>? in
                    guard case .command(let entry) = item, entry.command == .toggleTableDetails else { return nil }
                    return entry
                }
                .first
            let entry = try #require(found)
            #expect(entry.isOn == false)

            #expect(SidebarViewOptionsMenu.apply(entry.command))

            #expect(AppSettingsManager.shared.general.showTableDetails)
        }
    }
}
