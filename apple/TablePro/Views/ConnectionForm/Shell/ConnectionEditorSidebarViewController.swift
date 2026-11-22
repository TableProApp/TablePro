//
//  ConnectionEditorSidebarViewController.swift
//  TablePro
//

import AppKit

struct ConnectionEditorSidebarRow: Equatable {
    let facet: ConnectionFacet
    let title: String
    let symbolName: String
    let issueMessages: [String]

    var hasIssues: Bool { !issueMessages.isEmpty }

    var toolTip: String? {
        hasIssues ? issueMessages.joined(separator: "\n") : nil
    }

    var accessibilityLabel: String {
        guard let first = issueMessages.first else { return title }
        return String(format: String(localized: "%1$@, %2$@"), title, first)
    }

    // The layout's facets only, so a facet the type has no use for never shows; none while the record is gone.
    @MainActor
    static func rows(for store: ConnectionEditorStore) -> [ConnectionEditorSidebarRow] {
        guard !store.isRecordMissing else { return [] }
        return store.layout.facets.map { layout in
            ConnectionEditorSidebarRow(
                facet: layout.facet,
                title: layout.title,
                symbolName: layout.facet.symbolName,
                issueMessages: store.issues(for: layout.facet).filter { $0.blocksSave && store.isRevealed($0) }.map(\.message)
            )
        }
    }
}

// AppKit on purpose: a SwiftUI sidebar List keeps the previous row emphasized after a programmatic
// selection while it is not first responder, and making it first responder would take focus from
// the field that focus(on:) just moved to.
@MainActor
final class ConnectionEditorSidebarViewController: NSViewController {
    static let listIdentifier = "connection-editor-sidebar"
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ConnectionEditorSidebarCell")

    let tableView = NSTableView()
    private let scrollView = NSScrollView()

    var onSelectFacet: ((ConnectionFacet) -> Void)?

    private(set) var rows: [ConnectionEditorSidebarRow] = []
    private(set) var selectedFacet: ConnectionFacet?
    private var isReflecting = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorSidebarViewController does not support NSCoder init")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("facet"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.allowsTypeSelect = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier(Self.listIdentifier)
        tableView.setAccessibilityLabel(String(localized: "Connection Settings"))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let root = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    // Cells are reconfigured in place when only a mark changed, so typing never reloads the list.
    func show(_ rows: [ConnectionEditorSidebarRow], selecting facet: ConnectionFacet?) {
        _ = view
        if rows != self.rows {
            let facetsChanged = rows.map(\.facet) != self.rows.map(\.facet)
            self.rows = rows
            isReflecting = true
            if facetsChanged {
                tableView.reloadData()
            } else {
                for index in rows.indices {
                    let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ConnectionEditorSidebarCell
                    cell?.configure(rows[index])
                }
            }
            isReflecting = false
        }
        reflect(facet)
    }

    func cell(for facet: ConnectionFacet) -> ConnectionEditorSidebarCell? {
        guard let index = rows.firstIndex(where: { $0.facet == facet }) else { return nil }
        return tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ConnectionEditorSidebarCell
    }

    private func reflect(_ facet: ConnectionFacet?) {
        selectedFacet = facet
        isReflecting = true
        defer { isReflecting = false }
        guard let index = facet.flatMap({ facet in rows.firstIndex { $0.facet == facet } }) else {
            if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
            return
        }
        if tableView.selectedRow != index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(index)
    }
}

extension ConnectionEditorSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].title : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ConnectionEditorSidebarCell
            ?? ConnectionEditorSidebarCell(identifier: Self.cellIdentifier)
        cell.configure(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReflecting else { return }
        let index = tableView.selectedRow
        guard rows.indices.contains(index) else {
            reflect(selectedFacet)
            return
        }
        selectedFacet = rows[index].facet
        onSelectFacet?(rows[index].facet)
    }
}

// Keeps the imageView and textField outlets: the source list then tints the template glyph with the
// accent color, emphasizes the selected label and turns the glyph white.
final class ConnectionEditorSidebarCell: NSTableCellView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let issueMark = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let markImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        markImage?.accessibilityDescription = ""
        issueMark.image = markImage
        issueMark.imageScaling = .scaleProportionallyDown
        issueMark.setAccessibilityElement(false)
        issueMark.setContentHuggingPriority(.required, for: .horizontal)
        issueMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        for subview in [glyph, label, issueMark] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        imageView = glyph
        textField = label
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28.5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: issueMark.leadingAnchor, constant: -4),
            issueMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            issueMark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        tintIssueMark()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorSidebarCell does not support NSCoder init")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { tintIssueMark() }
    }

    func configure(_ row: ConnectionEditorSidebarRow) {
        // The table overwrites imageView.symbolConfiguration, so the size is baked into the image.
        let image = NSImage(systemSymbolName: row.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .body, scale: .large))
        // An empty description, not nil: nil still reads the symbol name to VoiceOver.
        image?.accessibilityDescription = ""
        glyph.image = image
        label.stringValue = row.title
        issueMark.isHidden = !row.hasIssues
        toolTip = row.toolTip
        // The table publishes its own cell element and drops this view's identifier, so the label carries it.
        label.setAccessibilityIdentifier("connection-editor-sidebar-\(row.facet.rawValue)")
        setAccessibilityLabel(row.accessibilityLabel)
    }

    // Red on a plain row, white on the emphasized selection where red would not read.
    private func tintIssueMark() {
        issueMark.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .systemRed
    }
}
