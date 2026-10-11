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
    }

    private static let moveTitle = String(localized: "Move Tab to Connection…")
    private static let newWindowTitle = String(localized: "Move Tab to New Window")

    private func commands(offers: Bool, can: Bool, recorder: Recorder = Recorder()) -> EditorTabCommands {
        EditorTabCommands(
            activate: { _ in },
            keepOpen: { _ in },
            canKeepOpen: { _ in false },
            close: { _ in },
            closeOthers: { _ in },
            closeAll: {},
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
}
