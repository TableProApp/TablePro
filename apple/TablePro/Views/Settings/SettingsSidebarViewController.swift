import AppKit

// AppKit on purpose: a SwiftUI sidebar List keeps the previous row's emphasized label after a
// programmatic selection change while it is not first responder, and making it first responder
// steals focus from the search field or a detail field.
@MainActor
internal final class SettingsSidebarViewController: NSViewController {
    internal static let searchIdentifier = "settings-sidebar-search"
    internal static let listIdentifier = "settings-sidebar"
    private static let spacerHeight: CGFloat = 12
    private static let paneCellIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarPaneCell")
    private static let pageCellIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarPageCell")

    internal let searchField = NSSearchField()
    internal let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let noResultsLabel = NSTextField(labelWithString: "")

    internal var onSelectPane: ((SettingsPane) -> Void)?
    internal var onOpenLocation: ((SettingsLocation) -> Void)?
    internal var searchEntries: () -> [SettingsSearchEntry] = { [] }

    internal private(set) var rows: [SettingsSidebarRow] = SettingsNavigation.rows(matching: "")
    private var query = ""
    private var location: SettingsLocation
    private var isReflecting = false

    internal init(location: SettingsLocation) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("SettingsSidebarViewController does not support NSCoder init")
    }

    override internal func loadView() {
        let root = NSView()
        configureSearchField()
        configureTable()
        configureNoResultsLabel()

        for subview in [searchField, scrollView, noResultsLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noResultsLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noResultsLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            noResultsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            noResultsLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root
    }

    override internal func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        reflect(location)
    }

    private func configureSearchField() {
        searchField.placeholderString = String(localized: "Search")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier(Self.searchIdentifier)
        if #available(macOS 26.0, *) {
            searchField.controlSize = .large
        } else {
            searchField.controlSize = .regular
        }
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        // A query that hides the current pane leaves nothing selected; allowsEmptySelection false
        // would select row 0 on every reload and navigate on each keystroke.
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.setAccessibilityIdentifier(Self.listIdentifier)
        tableView.setAccessibilityLabel(String(localized: "Settings sections"))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }

    private func configureNoResultsLabel() {
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.alignment = .center
        noResultsLabel.lineBreakMode = .byWordWrapping
        noResultsLabel.maximumNumberOfLines = 0
        noResultsLabel.isHidden = true
    }

    // MARK: - Location

    internal func reflect(_ location: SettingsLocation) {
        self.location = location
        guard isViewLoaded else { return }
        let index = row(for: location)
        isReflecting = true
        defer { isReflecting = false }
        if let index {
            if tableView.selectedRow != index {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            tableView.scrollRowToVisible(index)
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
    }

    private func row(for location: SettingsLocation) -> Int? {
        let pageRow = rows.firstIndex {
            if case .page(_, let rowLocation) = $0 { return rowLocation == location }
            return false
        }
        return pageRow ?? rows.firstIndex(of: .pane(location.pane))
    }

    // MARK: - Search

    internal var isFiltering: Bool {
        SettingsSearchIndex.isFiltering(query)
    }

    internal func filter(by text: String) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        applyQuery(text)
    }

    internal func clearSearch() {
        filter(by: "")
    }

    // Dynamic names changed (a plugin loaded, a provider was renamed), so a visible result list is stale.
    internal func reloadSearchResults() {
        guard isFiltering else { return }
        reloadRows()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        applyQuery(sender.stringValue)
    }

    private func applyQuery(_ text: String) {
        guard text != query else { return }
        query = text
        reloadRows()
    }

    private func reloadRows() {
        rows = SettingsNavigation.rows(matching: query, adding: isFiltering ? searchEntries() : [])
        isReflecting = true
        tableView.reloadData()
        isReflecting = false
        updateNoResults()
        reflect(location)
    }

    private func updateNoResults() {
        let isEmpty = rows.isEmpty && isFiltering
        noResultsLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        noResultsLabel.stringValue = String(format: String(localized: "No Results for “%@”"), query)
    }

    // Return or Down in the field goes to the first match, the way the System Settings search does.
    private func pickFirstMatch() -> Bool {
        guard let index = rows.firstIndex(where: \.isSelectable) else {
            NSSound.beep()
            return true
        }
        pick(rows[index])
        view.window?.makeFirstResponder(tableView)
        return true
    }

    // MARK: - Picking

    private func pick(_ row: SettingsSidebarRow) {
        switch row {
        case .pane(let pane):
            onSelectPane?(pane)
        case .page(_, let location):
            onOpenLocation?(location)
        case .spacer:
            break
        }
    }

    // A click on the row already selected sends no selection change, so it arrives here; on a
    // pane drilled into a page it returns to the pane's root.
    @objc private func rowClicked(_ sender: Any?) {
        let index = tableView.clickedRow
        guard index >= 0, index == tableView.selectedRow, rows.indices.contains(index) else { return }
        pick(rows[index])
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    internal func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    internal func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), case .spacer = rows[row] else { return tableView.rowHeight }
        return Self.spacerHeight
    }

    internal func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    internal func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .pane(let pane): return pane.title
        case .page(let title, _): return title
        case .spacer: return nil
        }
    }

    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .pane(let pane):
            let cell = tableView.makeView(withIdentifier: Self.paneCellIdentifier, owner: self) as? SettingsSidebarPaneCell
                ?? SettingsSidebarPaneCell(identifier: Self.paneCellIdentifier)
            cell.configure(pane)
            return cell
        case .page(let title, let location):
            let cell = tableView.makeView(withIdentifier: Self.pageCellIdentifier, owner: self) as? SettingsSidebarPageCell
                ?? SettingsSidebarPageCell(identifier: Self.pageCellIdentifier)
            cell.configure(title: title, location: location)
            return cell
        case .spacer:
            return nil
        }
    }

    internal func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReflecting else { return }
        let index = tableView.selectedRow
        guard rows.indices.contains(index) else {
            reflect(location)
            return
        }
        pick(rows[index])
    }
}

extension SettingsSidebarViewController: NSSearchFieldDelegate {
    internal func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        applyQuery(searchField.stringValue)
    }

    internal func searchFieldDidEndSearching(_ sender: NSSearchField) {
        applyQuery("")
    }

    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            return pickFirstMatch()
        case #selector(NSResponder.cancelOperation(_:)) where searchField.stringValue.isEmpty:
            view.window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }
}

private extension SettingsSidebarRow {
    var isSelectable: Bool {
        if case .spacer = self { return false }
        return true
    }
}

// Keeps the imageView and textField outlets: the source list then emphasizes the selected label
// and turns the template glyph white.
private final class SettingsSidebarPaneCell: NSTableCellView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for subview in [glyph, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        imageView = glyph
        textField = label
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28.5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsSidebarPaneCell does not support NSCoder init")
    }

    func configure(_ pane: SettingsPane) {
        // The table overwrites imageView.symbolConfiguration, so the size is baked into the image.
        let image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .body, scale: .large))
        // An empty description, not nil: nil still reads the symbol name ("Gear shape") to VoiceOver.
        image?.accessibilityDescription = ""
        glyph.image = image
        label.stringValue = pane.title
        setAccessibilityIdentifier("settings-sidebar-\(pane.rawValue)")
        setAccessibilityLabel(pane.title)
    }
}

private final class SettingsSidebarPageCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28.5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsSidebarPageCell does not support NSCoder init")
    }

    func configure(title: String, location: SettingsLocation) {
        label.stringValue = title
        setAccessibilityLabel(title)
        let pageIdentifier = location.routes.last?.page.map(\.urlIdentifier)
        setAccessibilityIdentifier(pageIdentifier.map { "settings-sidebar-page-\($0)" } ?? "")
    }
}
