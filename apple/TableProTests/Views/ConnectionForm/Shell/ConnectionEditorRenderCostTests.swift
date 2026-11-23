//
//  ConnectionEditorRenderCostTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class RenderCounter {
    var counts: [ConnectionFacet: Int] = [:]

    func hit(_ facet: ConnectionFacet) -> Int {
        counts[facet, default: 0] += 1
        return counts[facet, default: 0]
    }
}

// Observes the store the way every facet view does, so its body runs exactly when the facet's would.
private struct CountingFacetPage: View {
    @ObservedObject var store: ConnectionEditorStore
    let facet: ConnectionFacet
    let counter: RenderCounter

    var body: some View {
        let _ = counter.hit(facet)
        ConnectionEditorFacetPage(store: store, facet: facet)
    }
}

@MainActor
struct ConnectionEditorRenderCostTests {
    // A quarter of a 60 Hz frame for the pure part of a keystroke, on the slowest runner.
    private static let engineBudget = Duration.milliseconds(4)

    private func flush(_ window: NSWindow) {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date())
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    // Every transport a type offers, with an SSH host, a jump host and a masking rule, so each facet has rows.
    private func heaviestKeystroke(_ type: DatabaseType) -> (cost: Duration, label: String) {
        let traits = ConnectionTypeTraits.live(for: type, pluginManager: .shared)
        let base = ConnectionDraft.new(type: type, traits: traits)
        var worst = (cost: Duration.zero, label: "")
        for transport in ConnectionEditorEngine.availableTransports(base, traits) {
            var draft = base
            draft.selectTransport(transport)
            draft.ssh.host = "bastion.example.com"
            _ = draft.addJumpHost()
            _ = draft.addMaskingRule()
            let iterations = 40
            let elapsed = ContinuousClock().measure {
                for index in 0..<iterations {
                    var typed = draft
                    typed.host = "db\(index).example.com"
                    let layout = ConnectionEditorEngine.layout(typed, traits, EditorContext())
                    _ = ConnectionEditorEngine.issues(typed, traits, EditorContext(), layout: layout)
                }
            }
            if elapsed / iterations > worst.cost {
                worst = (elapsed / iterations, "\(type.rawValue) via \(transport?.rawValue ?? "direct")")
            }
        }
        return worst
    }

    @Test("Layout and issues for a keystroke stay within budget for every registered type")
    func engineStaysWithinBudget() {
        let rows = DatabaseType.allKnownTypes.map(heaviestKeystroke).sorted { $0.cost > $1.cost }
        for row in rows {
            #expect(row.cost < Self.engineBudget, "\(row.label): \(row.cost)")
        }
    }

    @Test("Typing in General renders General only, however many facets were visited")
    func typingRendersTheShownFacetOnly() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.selectTransport(.ssh)
        let counter = RenderCounter()
        let detail = ConnectionEditorDetailViewController(store: store, onCloseMissingRecord: {}) { facet in
            AnyView(CountingFacetPage(store: store, facet: facet, counter: counter))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        detail.view.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
        detail.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(detail.view)
        for facet in store.layout.facetIDs + [.general] {
            detail.show(.facet(facet))
            flush(window)
        }
        #expect(detail.visitedFacets == Set(store.layout.facetIDs))
        for facet in store.layout.facetIDs where facet != .general {
            #expect(detail.host(for: facet)?.view.window == nil, "\(facet)")
        }

        let before = counter.counts
        let keystrokes = 10
        for index in 0..<keystrokes {
            store.setHost("db\(index).example.com", undoManager: nil)
            flush(window)
        }
        let rendered = store.layout.facetIDs.reduce(into: [ConnectionFacet: Int]()) { result, facet in
            result[facet] = counter.counts[facet, default: 0] - before[facet, default: 0]
        }
        #expect(rendered[.general, default: 0] >= 1)
        #expect(rendered[.general, default: 0] <= keystrokes)
        for facet in store.layout.facetIDs where facet != .general {
            #expect(rendered[facet] == 0, "\(facet)")
        }

        let parked = counter.counts[.advanced, default: 0]
        detail.show(.facet(.advanced))
        flush(window)
        #expect(counter.counts[.advanced, default: 0] > parked)
    }
}
