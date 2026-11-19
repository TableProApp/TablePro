//
//  EditorTabStripSnapshotTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabStripSnapshotTests {
    private func items(
        _ tabs: [QueryTab],
        selected: UUID? = nil,
        busy: Set<UUID> = []
    ) -> [EditorTabItem] {
        EditorTabStripSnapshot.items(tabs: tabs, selectedId: selected, target: nil, isBusy: { busy.contains($0) })
    }

    private func tab(_ title: String, outcome: TabUnseenOutcome? = nil) -> QueryTab {
        var tab = QueryTab(title: title)
        tab.execution.unseenOutcome = outcome
        return tab
    }

    @Test("Items keep the tab order and know their position")
    func itemsKeepOrder() {
        let tabs = [tab("Album"), tab("Artist")]
        let result = items(tabs, selected: tabs[1].id)

        #expect(result.map(\.title) == ["Album", "Artist"])
        #expect(result.map(\.position) == [1, 2])
        #expect(result.allSatisfy { $0.count == 2 })
        #expect(result.map(\.isSelected) == [false, true])
    }

    @Test("A running tab reports running, selected or not")
    func runningOutranksEverything() {
        let running = tab("Album", outcome: .failed)
        let result = items([running], selected: running.id, busy: [running.id])

        #expect(result.first?.status == .running)
    }

    @Test("An unseen outcome shows only on a tab that is not selected")
    func unseenOutcomeNeedsABackgroundTab() {
        let failed = tab("Album", outcome: .failed)
        let finished = tab("Artist", outcome: .succeeded)

        let background = items([failed, finished])
        #expect(background.map(\.status) == [.failed, .finished])

        let foreground = items([failed, finished], selected: failed.id)
        #expect(foreground.first?.status == .idle)
    }

    @Test("A preview tab's tooltip says how to keep it")
    func previewTooltip() {
        var preview = tab("Album")
        preview.isPreview = true

        #expect(items([preview]).first?.tooltip.contains("Album") == true)
        #expect(items([preview]).first?.tooltip != items([tab("Album")]).first?.tooltip)
    }

    @Test("Accessibility hears the states the drawing shows")
    func accessibilityDescribesState() {
        let item = EditorTabItem.sample(isPinned: true, isPreview: true, status: .running, position: 2, count: 3)
        let description = item.accessibilityDescription

        #expect(description.contains("2"))
        #expect(description.contains("3"))
        #expect(description != EditorTabItem.sample(position: 2, count: 3).accessibilityDescription)
    }
}
