//
//  TreeOutlineFixture.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
internal final class TreeOutlineClipboard: ClipboardProvider {
    var writes: [String] = []

    func readText() -> String? { writes.last }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { writes.append(text) }
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {}
    var hasText: Bool { !writes.isEmpty }
    var hasGridRows: Bool { false }
}

@MainActor
internal final class OpenedLinks {
    var urls: [URL] = []
}

internal enum TreeOutlineFixture {
    static var fonts: TreeOutlineFonts {
        TreeOutlineFonts(
            value: .monospacedSystemFont(ofSize: 13, weight: .regular),
            key: .monospacedSystemFont(ofSize: 13, weight: .medium)
        )
    }

    static let invoice = #"{"invoice":{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false},"note":"x"}"#

    static let profile = """
    {"name":"Acme","site":"https://example.com/docs","brand":"#ff8800",\
    "theme":{"ink":"#1e1e1e","deep":{"leaf":1}},"count":42}
    """

    static func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json, formats: .english).get()
    }

    /// Every copy in these suites goes to a fake, and the real clipboard is put back afterwards.
    @MainActor
    static func withClipboard<Result>(_ body: (TreeOutlineClipboard) throws -> Result) rethrows -> Result {
        let original = ClipboardService.shared
        defer { ClipboardService.shared = original }
        let clipboard = TreeOutlineClipboard()
        ClipboardService.shared = clipboard
        return try body(clipboard)
    }

    /// No test opens a browser: the opener is replaced for the length of `body` and then restored.
    @MainActor
    static func withOpener<Result>(_ body: (OpenedLinks) throws -> Result) rethrows -> Result {
        let original = DataLinkPolicy.opener
        defer { DataLinkPolicy.opener = original }
        let opened = OpenedLinks()
        DataLinkPolicy.opener = { opened.urls.append($0) }
        return try body(opened)
    }

    /// An https link whose host starts with a trusted-looking name and ends `offset` UTF-16 units
    /// into the value, on a domain someone else owns.
    static func link(hostEndingAt offset: Int) -> String {
        let scheme = "https://"
        let trusted = "login.example-bank.com."
        let owner = "attacker.example"
        let filler = offset - scheme.count - trusted.count - owner.count
        let labels = String(repeating: "a.", count: filler / 2) + String(repeating: "b", count: filler % 2)
        return scheme + trusted + labels + owner + "/signin?next=" + String(repeating: "c", count: 400)
    }

    static func marker(under parent: TreeNodePath = .root) -> JSONTreeNode {
        JSONTreeNode(
            key: nil, keyPath: "", path: parent.appending(.truncationMarker), valueType: .truncated,
            displayValue: "… (3 more)", rawValue: nil, children: []
        )
    }
}

/// A light theme on the shared engine for the length of `body`, then the original pair back.
/// Synchronous and main-actor, so no suite running in parallel sees it.
@MainActor
internal enum TreeThemeFixture {
    /// One distinct color for each slot a tree reads.
    static let tones: [ThemeSlot: String] = [
        .syntaxString: "#B00001",
        .syntaxNumber: "#B00002",
        .syntaxNull: "#B00003",
        .syntaxType: "#B00004",
        .syntaxComment: "#B00005",
        .syntaxKeyword: "#B00006",
        .editorText: "#B00007",
        .editorLineNumber: "#B00008"
    ]

    static func with<Result>(_ overrides: [ThemeSlot: String], _ body: () throws -> Result) throws -> Result {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: try pair(overrides), effectiveAppearance: .light))
        return try body()
    }

    /// Adopted over a pair that is already live, so the change reaches subscribers that exist now.
    static func adopt(_ overrides: [ThemeSlot: String]) throws {
        ThemeEngine.shared.adopt(ThemeSelection(pair: try pair(overrides), effectiveAppearance: .light))
    }

    static func hex(_ color: NSColor?, in name: NSAppearance.Name = .aqua) -> String? {
        guard let color, let appearance = NSAppearance(named: name) else { return nil }
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    private static func pair(_ overrides: [ThemeSlot: String]) throws -> ThemePair {
        guard !overrides.isEmpty else { return .builtIn }
        var light = BuiltInThemes.light
        light.id = "user.test.tree"
        for (slot, hex) in overrides {
            light.overrides[slot] = try ThemeColor(validating: hex)
        }
        return ThemePair(light: light, dark: BuiltInThemes.dark)
    }
}

/// The wiring `FilterableTreeView` gives the coordinator, without SwiftUI: the disclosure state
/// lives here, and a row the outline reports as opened or closed is written back into it.
@MainActor
internal final class TreeOutlineHarness {
    typealias Item = TreeOutlineItem<JSONTreeNode>

    let outline = TreeOutlineView.make()
    /// A table with no clip view above it counts every row as visible and builds a view for each.
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let cache = TreeProjectionCache<JSONTreeNode>()
    let coordinator: TreeOutlineCoordinator<JSONTreeNode>
    var root: JSONTreeNode
    var searchText = ""
    var disclosure = TreeDisclosureState()
    var fonts = TreeOutlineFixture.fonts
    var reported: [TreeNodePath] = []
    var expandAllCount = 0
    var collapseAllCount = 0

    init(json: String) throws {
        root = try TreeOutlineFixture.parse(json)
        coordinator = TreeOutlineCoordinator(cache: cache)
        scrollView.documentView = outline
        coordinator.attach(outline)
        coordinator.onSetExpanded = { [weak self] path, isExpanded in
            guard let self else { return }
            reported.append(path)
            disclosure.setExpanded(isExpanded, path: path, isFiltered: projection.isFiltered)
        }
        coordinator.onExpandAll = { [weak self] in self?.expandAllCount += 1 }
        coordinator.onCollapseAll = { [weak self] in self?.collapseAllCount += 1 }
        apply()
    }

    var projection: TreeProjection<JSONTreeNode> {
        cache.projection(for: root, searchText: searchText)
    }

    func apply() {
        coordinator.apply(
            TreeOutlineContent(
                rootNode: root,
                searchText: searchText,
                projection: projection,
                documentInfo: cache.documentInfo(for: root),
                disclosure: disclosure
            ),
            fonts: fonts
        )
    }

    func filter(_ text: String) {
        searchText = text
        apply()
    }

    func reparse(_ json: String) throws {
        root = try TreeOutlineFixture.parse(json)
        apply()
    }

    var items: [Item] {
        (0 ..< outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Item }
    }

    var keys: [String] {
        items.map { $0.node.key ?? "" }
    }

    func row(_ key: String) throws -> Int {
        try #require(items.firstIndex { $0.node.key == key }, "no visible row has the key \(key)")
    }

    func cell(_ key: String) throws -> TreeOutlineCellView {
        let view = outline.view(atColumn: 0, row: try row(key), makeIfNecessary: false)
        return try #require(view as? TreeOutlineCellView)
    }

    func item(_ key: String) throws -> Item {
        try #require(items.first { $0.node.key == key }, "no visible row has the key \(key)")
    }

    func select(_ keys: String...) throws {
        let rows = try keys.map { try row($0) }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    var selectedKeys: [String] {
        coordinator.selectedItems().map { $0.node.key ?? "" }
    }
}
