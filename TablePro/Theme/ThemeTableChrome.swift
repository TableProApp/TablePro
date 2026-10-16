import AppKit
import Combine
import SwiftUI
import TableProTheme

/// Themes an `NSTableView` or `NSOutlineView` that shows content. Never a source list: its selection
/// and background belong to the sidebar glass, which draws them without calling the row view.
///
/// A property is written only while the active theme sets its slot, and gets back the value it had
/// once the theme stops, so under a default theme the table is exactly what AppKit draws. Rows take
/// the theme's background and selection through a `ThemeTableRowDrawing` row, and only while the
/// theme sets one of them: a row class that overrides a drawing method leaves AppKit's layer-backed
/// selection, the vibrant material in a popover among them.
@MainActor
internal final class ThemeTableChrome {
    internal enum Family {
        /// Records and schema objects, on the data grid's slots.
        case records
        /// Values and code, on the editor's slots.
        case code

        internal var background: ThemeSlot {
            switch self {
            case .records: return .gridBackground
            case .code: return .editorBackground
            }
        }

        internal var alternateRow: ThemeSlot? {
            switch self {
            case .records: return .gridAlternateRow
            case .code: return nil
            }
        }

        internal var gridLine: ThemeSlot? {
            switch self {
            case .records: return .gridLine
            case .code: return nil
            }
        }

        /// The data grid's header slots. A code table's header, where it has one, stays AppKit's.
        internal var headerSlots: [ThemeSlot] {
            switch self {
            case .records: return [.gridHeaderBackground, .gridHeaderText]
            case .code: return []
            }
        }

        internal func selection(emphasized: Bool) -> ThemeSlot {
            switch self {
            case .records: return emphasized ? .gridSelection : .gridInactiveSelection
            case .code: return .editorSelection
            }
        }
    }

    private struct BackgroundOriginals {
        let color: NSColor
        let alternates: Bool
    }

    internal let family: Family
    internal let scope: ThemeScope

    /// True while the theme sets the rows' background or a selection, which only a themed row class
    /// draws. A delegate returns AppKit's own row view otherwise.
    internal private(set) var themesRows = false

    /// True while the rows are rebuilt for a new row class. The expansion and selection AppKit
    /// reports meanwhile are the ones the table already had.
    internal private(set) var isRebuildingRows = false

    private weak var tableView: NSTableView?
    private var backgroundOriginals: BackgroundOriginals?
    private weak var themedScrollView: NSScrollView?
    private var scrollViewDrewBackground = true
    private var originalGridColor: NSColor?
    private var originalHeaderView: NSTableHeaderView?
    private var originalCornerView: NSView?
    private var themeCancellable: AnyCancellable?

    /// Attach before the table builds its rows, and once it is inside its scroll view.
    internal init(tableView: NSTableView, family: Family, scope: ThemeScope = .live) {
        self.tableView = tableView
        self.family = family
        self.scope = scope
        restyle()
        themeCancellable = scope.changes
            .sink { [weak self] _ in self?.apply() }
    }

    internal var isBackgroundThemed: Bool {
        backgroundOriginals != nil
    }

    /// True while the table's header is a `ThemeTableHeaderView` in place of the one its owner gave it.
    internal var isHeaderThemed: Bool {
        originalHeaderView != nil
    }

    internal func apply() {
        restyle()
        guard let tableView, hasStaleRows(in: tableView) else { return }
        rebuildRows(of: tableView)
    }

    /// Nil while the theme leaves the rows alone, so the table builds AppKit's own row view.
    internal func makeRowView(in tableView: NSTableView) -> ThemeTableRowView? {
        guard themesRows else { return nil }
        let reused = tableView.makeView(withIdentifier: ThemeTableRowView.reuseIdentifier, owner: nil)
        let rowView = reused as? ThemeTableRowView ?? ThemeTableRowView()
        rowView.identifier = ThemeTableRowView.reuseIdentifier
        rowView.chrome = self
        return rowView
    }

    /// Nil while the theme leaves the background alone, and the row draws AppKit's. A themed table
    /// stripes its rows itself: AppKit's stripes are the system pair whatever the table's color.
    internal func rowBackgroundColor(forRow row: Int) -> NSColor? {
        guard let originals = backgroundOriginals, row >= 0 else { return nil }
        let palette = scope.palette
        guard originals.alternates, let alternate = family.alternateRow, !row.isMultiple(of: 2) else {
            return palette[family.background]
        }
        return palette[alternate]
    }

    /// Nil unless the theme sets its own selection, so a default theme keeps AppKit's, which follows
    /// Accent and focus.
    internal func selectionColor(emphasized: Bool) -> NSColor? {
        let resolved = scope.resolved
        let slot = family.selection(emphasized: emphasized)
        return resolved.isOverridden(slot) ? resolved[slot] : nil
    }

    internal func isOnThemedSelection(_ rowView: NSTableRowView) -> Bool {
        rowView.isSelected && selectionColor(emphasized: rowView.isEmphasized) != nil
    }

    private func restyle() {
        guard let tableView else { return }
        let resolved = scope.resolved
        let backgroundSlots = [family.background] + [family.alternateRow].compactMap { $0 }
        applyBackground(to: tableView, themed: backgroundSlots.contains { resolved.isOverridden($0) })
        applyGridColor(to: tableView, themed: family.gridLine.map { resolved.isOverridden($0) } ?? false)
        applyHeader(to: tableView, themed: family.headerSlots.contains { resolved.isOverridden($0) })
        let selectionSlots = [family.selection(emphasized: true), family.selection(emphasized: false)]
        themesRows = isBackgroundThemed || selectionSlots.contains { resolved.isOverridden($0) }
        tableView.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            (rowView as? ThemeTableRowView)?.publishSelection()
        }
    }

    private func hasStaleRows(in tableView: NSTableView) -> Bool {
        let themesRows = themesRows
        var isStale = false
        tableView.enumerateAvailableRowViews { rowView, _ in
            if (rowView is any ThemeTableRowDrawing) != themesRows { isStale = true }
        }
        return isStale
    }

    /// AppKit asks for a row view only when it builds a row, so a new class needs a reload. An
    /// outline drops its selection on a reload, and the clip view clamps while rows are rebuilt.
    private func rebuildRows(of tableView: NSTableView) {
        isRebuildingRows = true
        defer { isRebuildingRows = false }
        let origin = tableView.enclosingScrollView?.contentView.bounds.origin
        if let window = tableView.window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView, field.isDescendant(of: tableView) {
            window.makeFirstResponder(tableView)
        }
        if let outlineView = tableView as? NSOutlineView {
            reload(outlineView)
        } else {
            let selection = tableView.selectedRowIndexes
            tableView.reloadData()
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
        }
        if let origin {
            tableView.scroll(origin)
        }
    }

    private func reload(_ outlineView: NSOutlineView) {
        let items = (0 ..< outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) }
        let expanded = items.filter { outlineView.isItemExpanded($0) }
        let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }
        outlineView.reloadData()
        outlineView.beginUpdates()
        for item in expanded where !outlineView.isItemExpanded(item) {
            outlineView.expandItem(item)
        }
        outlineView.endUpdates()
        let rows = IndexSet(selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// The scroll view's own background is the content-background material; a themed table drops it
    /// so the material never shows through an elastic scroll.
    private func applyBackground(to tableView: NSTableView, themed: Bool) {
        guard themed else {
            restoreBackground(of: tableView)
            return
        }
        if backgroundOriginals == nil {
            backgroundOriginals = BackgroundOriginals(
                color: tableView.backgroundColor,
                alternates: tableView.usesAlternatingRowBackgroundColors
            )
        }
        tableView.backgroundColor = scope.palette[family.background]
        tableView.usesAlternatingRowBackgroundColors = false

        if let scrollView = tableView.enclosingScrollView, scrollView !== themedScrollView {
            restoreScrollView()
            themedScrollView = scrollView
            scrollViewDrewBackground = scrollView.drawsBackground
        }
        themedScrollView?.drawsBackground = false
    }

    private func restoreBackground(of tableView: NSTableView) {
        guard let originals = backgroundOriginals else { return }
        tableView.backgroundColor = originals.color
        tableView.usesAlternatingRowBackgroundColors = originals.alternates
        restoreScrollView()
        backgroundOriginals = nil
    }

    private func restoreScrollView() {
        themedScrollView?.drawsBackground = scrollViewDrewBackground
        themedScrollView = nil
    }

    private func applyGridColor(to tableView: NSTableView, themed: Bool) {
        guard let slot = family.gridLine else { return }
        guard themed else {
            if let original = originalGridColor {
                tableView.gridColor = original
                originalGridColor = nil
            }
            return
        }
        if originalGridColor == nil {
            originalGridColor = tableView.gridColor
        }
        tableView.gridColor = scope.palette[slot]
    }

    /// AppKit's header paints its own band over anything beneath it, so a themed header is ours and
    /// the owner's comes back when the theme stops coloring it.
    private func applyHeader(to tableView: NSTableView, themed: Bool) {
        guard themed else {
            restoreHeader(of: tableView)
            return
        }
        if let header = tableView.headerView as? ThemeTableHeaderView, header.chrome === self {
            header.needsDisplay = true
            tableView.cornerView?.needsDisplay = true
            return
        }
        guard let original = tableView.headerView else { return }
        originalHeaderView = original
        originalCornerView = tableView.cornerView

        let header = ThemeTableHeaderView(frame: original.frame)
        header.chrome = self
        header.menu = original.menu
        tableView.headerView = header
        let corner = ThemeTableCornerView(frame: originalCornerView?.frame ?? .zero)
        corner.chrome = self
        tableView.cornerView = corner
    }

    private func restoreHeader(of tableView: NSTableView) {
        guard let original = originalHeaderView else { return }
        tableView.headerView = original
        tableView.cornerView = originalCornerView
        originalHeaderView = nil
        originalCornerView = nil
    }
}

// MARK: - Header

/// Drawn like the data grid's header. Each title goes through its cell's interior drawing, which
/// keeps AppKit's alignment and truncation. The sort indicator is drawn here because AppKit draws it
/// from the header view's own pass, which this replaces.
internal final class ThemeTableHeaderView: NSTableHeaderView {
    internal weak var chrome: ThemeTableChrome?

    override internal func draw(_ dirtyRect: NSRect) {
        guard let chrome, let tableView else {
            super.draw(dirtyRect)
            return
        }
        let scope = chrome.scope
        SortableHeaderChrome.fillBackground(dirtyRect, scope: scope)
        let textColor = scope.resolved[.gridHeaderText]
        let dragged = draggedColumn
        for index in tableView.tableColumns.indices where index != dragged {
            drawHeading(ofColumn: index, at: headerRect(ofColumn: index), in: dirtyRect, textColor: textColor, scope: scope)
        }
        // A column being dragged follows the pointer over its neighbours, as AppKit's header draws it.
        if dragged >= 0, dragged < tableView.tableColumns.count {
            let floating = headerRect(ofColumn: dragged).offsetBy(dx: draggedDistance, dy: 0)
            if floating.intersects(dirtyRect) {
                SortableHeaderChrome.fillBackground(floating, scope: scope)
            }
            drawHeading(ofColumn: dragged, at: floating, in: dirtyRect, textColor: textColor, scope: scope)
        }
        SortableHeaderChrome.drawBottomSeparator(in: bounds, scope: scope)
    }

    private func drawHeading(ofColumn index: Int, at heading: NSRect, in dirtyRect: NSRect, textColor: NSColor, scope: ThemeScope) {
        guard let tableView, heading.width > 0, heading.intersects(dirtyRect) else { return }
        let column = tableView.tableColumns[index]
        let cell = column.headerCell
        let nativeTextColor = cell.textColor
        cell.textColor = textColor
        if let sort = sortState(of: column, in: tableView) {
            var title = heading
            title.size.width = max(0, cell.sortIndicatorRect(forBounds: heading).minX - heading.minX)
            cell.drawInterior(withFrame: title, in: self)
            cell.drawSortIndicator(withFrame: heading, in: self, ascending: sort.ascending, priority: sort.priority)
        } else {
            cell.drawInterior(withFrame: heading, in: self)
        }
        cell.textColor = nativeTextColor
        SortableHeaderChrome.drawColumnDivider(in: heading, scope: scope)
    }

    /// AppKit shows only the primary sort key's indicator.
    private func sortState(of column: NSTableColumn, in tableView: NSTableView) -> (ascending: Bool, priority: Int)? {
        guard let key = column.sortDescriptorPrototype?.key,
              let primary = tableView.sortDescriptors.first, primary.key == key
        else { return nil }
        return (primary.ascending, 0)
    }
}

/// The square over the vertical scroller beside a themed header, which AppKit would paint in its own
/// header band.
internal final class ThemeTableCornerView: NSView {
    internal weak var chrome: ThemeTableChrome?

    override internal var isFlipped: Bool { true }

    override internal func draw(_ dirtyRect: NSRect) {
        let scope = chrome?.scope ?? .live
        SortableHeaderChrome.fillBackground(dirtyRect, scope: scope)
        SortableHeaderChrome.drawBottomSeparator(in: bounds, scope: scope)
    }
}

// MARK: - Row drawing

/// A row class that draws through its `ThemeTableChrome`. Each row class forwards its drawing
/// overrides here, so they exist only on a class the table uses while the theme draws its rows.
@MainActor
internal protocol ThemeTableRowDrawing: NSTableRowView {
    var chrome: ThemeTableChrome? { get set }
}

internal extension ThemeTableChrome {
    /// False while the theme leaves the row's background alone, and the row draws AppKit's.
    func drawBackground(of rowView: NSTableRowView, in dirtyRect: NSRect) -> Bool {
        guard !rowView.isGroupRowStyle,
              let tableView = rowView.superview as? NSTableView,
              let fill = rowBackgroundColor(forRow: tableView.row(for: rowView))
        else { return false }
        fill.setFill()
        dirtyRect.fill()
        return true
    }

    /// AppKit's selection recolored rather than replaced, so it keeps the shape the table style gives
    /// it: inset and rounded in an inset table, full width in a plain one.
    func drawSelection(of rowView: NSTableRowView, in dirtyRect: NSRect, native: (NSRect) -> Void) {
        guard let fill = selectionColor(emphasized: rowView.isEmphasized),
              let context = NSGraphicsContext.current?.cgContext
        else {
            native(dirtyRect)
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        native(dirtyRect)
        fill.setFill()
        dirtyRect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A theme picks its selection to sit behind its own text, so the text does not flip to white.
    func interiorBackgroundStyle(of rowView: NSTableRowView, native: NSView.BackgroundStyle) -> NSView.BackgroundStyle {
        isOnThemedSelection(rowView) ? .normal : native
    }
}

/// The row a `ThemeTableChrome` hands out while the theme draws the rows. It tells its records cells
/// when they sit on the theme's selection.
internal final class ThemeTableRowView: NSTableRowView, ThemeTableRowDrawing {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThemeTableRow")

    internal weak var chrome: ThemeTableChrome? {
        didSet { publishSelection() }
    }

    override internal var isSelected: Bool {
        didSet { publishSelection() }
    }

    override internal var isEmphasized: Bool {
        didSet { publishSelection() }
    }

    override internal func drawBackground(in dirtyRect: NSRect) {
        guard chrome?.drawBackground(of: self, in: dirtyRect) == true else {
            super.drawBackground(in: dirtyRect)
            return
        }
    }

    override internal func drawSelection(in dirtyRect: NSRect) {
        guard let chrome else {
            super.drawSelection(in: dirtyRect)
            return
        }
        chrome.drawSelection(of: self, in: dirtyRect) { super.drawSelection(in: $0) }
    }

    override internal var interiorBackgroundStyle: NSView.BackgroundStyle {
        let native = super.interiorBackgroundStyle
        return chrome?.interiorBackgroundStyle(of: self, native: native) ?? native
    }

    internal var isOnThemedSelection: Bool {
        chrome?.isOnThemedSelection(self) ?? false
    }

    internal func publishSelection() {
        let isThemed = isOnThemedSelection
        for case let cell as ThemeTableChrome.HostingCell in subviews {
            cell.isOnThemedSelection = isThemed
        }
    }
}

// MARK: - Records cell text

internal extension ThemeTableChrome {
    /// The slot a records cell's text takes, or nil for the cell's own hierarchical text, which
    /// turns white on AppKit's emphasized selection.
    static func recordsTextSlot(
        onThemedSelection: Bool,
        onEmphasizedSelection: Bool,
        highContrast: Bool,
        scope: ThemeScope = .live
    ) -> ThemeSlot? {
        guard !onEmphasizedSelection else { return nil }
        let theme = scope.activeTheme
        if onThemedSelection, theme.isOverridden(.gridSelectionText, highContrast: highContrast) {
            return .gridSelectionText
        }
        return theme.isOverridden(.gridText, highContrast: highContrast) ? .gridText : nil
    }

    /// A SwiftUI cell of a records table. Its text takes the theme's grid text, and the selection text
    /// while its `ThemeTableRowView` sits on the theme's selection.
    final class HostingCell: NSHostingView<AnyView> {
        private let selection = RecordsCellSelection()
        private var scope = ThemeScope.live

        internal var isOnThemedSelection: Bool {
            get { selection.isThemed }
            set {
                guard selection.isThemed != newValue else { return }
                selection.isThemed = newValue
            }
        }

        /// `scope` is the one the table's chrome reads, so the text matches the rows.
        internal static func make(
            _ identifier: NSUserInterfaceItemIdentifier,
            in tableView: NSTableView,
            showing content: some View,
            scope: ThemeScope = .live
        ) -> HostingCell {
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingCell
                ?? HostingCell(identifier: identifier)
            cell.scope = scope
            cell.show(content)
            return cell
        }

        private convenience init(identifier: NSUserInterfaceItemIdentifier) {
            self.init(rootView: AnyView(EmptyView()))
            sizingOptions = []
            self.identifier = identifier
        }

        internal func show(_ content: some View) {
            rootView = AnyView(content.modifier(RecordsCellText(selection: selection, scope: scope)))
        }

        /// A reused cell can land in another row, or in AppKit's own row view once the theme stops.
        override internal func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            isOnThemedSelection = (superview as? ThemeTableRowView)?.isOnThemedSelection ?? false
        }
    }
}

@MainActor
private final class RecordsCellSelection: ObservableObject {
    @Published var isThemed = false
}

private struct RecordsCellText: ViewModifier {
    @ObservedObject var selection: RecordsCellSelection
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    let scope: ThemeScope

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.modifier(
                ProminenceAwareRecordsCellText(
                    isOnThemedSelection: selection.isThemed,
                    scope: scope,
                    contrast: contrast
                )
            )
        } else {
            content
        }
    }
}

/// macOS 13 has no `backgroundProminence`, so a cell there cannot tell AppKit's emphasized selection
/// apart and keeps its system text.
@available(macOS 14, *)
private struct ProminenceAwareRecordsCellText: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    let isOnThemedSelection: Bool
    let scope: ThemeScope
    let contrast: ColorSchemeContrast

    func body(content: Content) -> some View {
        let slot = ThemeTableChrome.recordsTextSlot(
            onThemedSelection: isOnThemedSelection,
            onEmphasizedSelection: prominence == .increased,
            highContrast: contrast == .increased,
            scope: scope
        )
        if let slot {
            content.foregroundStyle(Color(nsColor: scope.palette[slot]))
        } else {
            content
        }
    }
}
