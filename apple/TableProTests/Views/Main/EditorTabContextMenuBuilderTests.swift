//
//  EditorTabContextMenuBuilderTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct EditorTabContextMenuBuilderTests {
    private final class Recorder {
        var moved: [UUID] = []
        var pinned: [(UUID, Bool)] = []
    }

    private static let moveTitle = String(localized: "Move Tab to Connection…")
    private static let newWindowTitle = String(localized: "Move Tab to New Window")

    private func commands(
        offers: Bool,
        can: Bool,
        recorder: Recorder = Recorder(),
        pinned: Bool = false,
        canCloseOthers: Bool = true,
        canCloseAll: Bool = true
    ) -> EditorTabCommands {
        EditorTabCommands(
            activate: { _ in },
            keepOpen: { _ in },
            canKeepOpen: { _ in false },
            isPinned: { _ in pinned },
            setPinned: { recorder.pinned.append(($0, $1)) },
            close: { _ in },
            closeOthers: { _ in },
            canCloseOthers: { _ in canCloseOthers },
            closeAll: {},
            canCloseAll: { canCloseAll },
            moveTab: { _, _ in },
            canMove: { _, _ in true },
            moveBy: { _, _ in },
            tearOff: { _ in },
            canTearOff: { _ in true },
            moveToConnection: { recorder.moved.append($0) },
            offersMoveToConnection: { _ in offers },
            canMoveToConnection: { _ in can },
            tooltip: { _ in "" }
        )
    }

    @Test("A movable query tab offers Move Tab to Connection right after Move Tab to New Window")
    func queryTabOffersTheMove() throws {
        let tabId = UUID()
        let recorder = Recorder()
        let menu = EditorTabContextMenuBuilder.menu(for: tabId, commands: commands(offers: true, can: true, recorder: recorder))
        let titles = menu.items.map(\.title)

        let newWindow = try #require(titles.firstIndex(of: Self.newWindowTitle))
        let move = try #require(titles.firstIndex(of: Self.moveTitle))
        #expect(move == newWindow + 1)

        let item = menu.items[move]
        #expect(item.isEnabled)
        (item.target as? ClosureMenuTarget)?.fire()
        #expect(recorder.moved == [tabId])
    }

    @Test("A query tab that cannot move now shows the item dimmed")
    func busyQueryTabDimsTheMove() {
        let menu = EditorTabContextMenuBuilder.menu(for: UUID(), commands: commands(offers: true, can: false))
        let item = menu.items.first { $0.title == Self.moveTitle }

        #expect(item != nil)
        #expect(item?.isEnabled == false)
    }

    @Test("A tab that is not a query tab does not show the item")
    func otherTabsHideTheMove() {
        let menu = EditorTabContextMenuBuilder.menu(for: UUID(), commands: commands(offers: false, can: true))
        let titles = menu.items.map(\.title)

        #expect(!titles.contains(Self.moveTitle))
        #expect(titles.contains(Self.newWindowTitle))
    }

    @Test("An unpinned tab offers Pin Tab right after Keep Open, and choosing it pins that tab")
    func unpinnedTabOffersPin() throws {
        let tabId = UUID()
        let recorder = Recorder()
        let menu = EditorTabContextMenuBuilder.menu(
            for: tabId,
            commands: commands(offers: false, can: false, recorder: recorder)
        )
        let titles = menu.items.map(\.title)

        let keepOpen = try #require(titles.firstIndex(of: String(localized: "Keep Open")))
        #expect(titles[keepOpen + 1] == String(localized: "Pin Tab"))
        #expect(!titles.contains(String(localized: "Unpin Tab")))

        (menu.items[keepOpen + 1].target as? ClosureMenuTarget)?.fire()
        #expect(recorder.pinned.count == 1)
        #expect(recorder.pinned.first?.0 == tabId)
        #expect(recorder.pinned.first?.1 == true)
    }

    @Test("A pinned tab offers Unpin Tab, and choosing it unpins")
    func pinnedTabOffersUnpin() throws {
        let recorder = Recorder()
        let menu = EditorTabContextMenuBuilder.menu(
            for: UUID(),
            commands: commands(offers: false, can: false, recorder: recorder, pinned: true)
        )
        let item = try #require(menu.items.first { $0.title == String(localized: "Unpin Tab") })

        (item.target as? ClosureMenuTarget)?.fire()
        #expect(recorder.pinned.first?.1 == false)
    }

    @Test("Close Other Tabs and Close All Tabs dim when they would close nothing")
    func idleBulkClosesDim() {
        let menu = EditorTabContextMenuBuilder.menu(
            for: UUID(),
            commands: commands(offers: false, can: false, canCloseOthers: false, canCloseAll: false)
        )
        let others = menu.items.first { $0.title == String(localized: "Close Other Tabs") }
        let all = menu.items.first { $0.title == String(localized: "Close All Tabs") }
        let close = menu.items.first { $0.title == String(localized: "Close Tab") }

        #expect(others?.isEnabled == false)
        #expect(all?.isEnabled == false)
        #expect(close?.isEnabled == true)
    }
}
