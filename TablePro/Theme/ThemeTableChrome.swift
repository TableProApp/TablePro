import AppKit
import Combine

/// Themes an `NSTableView` or `NSOutlineView` that shows content. Never a source list: its selection
/// and background belong to the sidebar glass, which draws them without calling the row view.
///
/// A property is written only while the active theme sets its slot, and gets back the value it had
/// once the theme stops, so under a default theme the table is exactly what AppKit draws. Rows take
/// the theme's background and selection through `ThemeTableRowView`.
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

    private weak var tableView: NSTableView?
    private var backgroundOriginals: BackgroundOriginals?
    private weak var themedScrollView: NSScrollView?
    private var scrollViewDrewBackground = true
    private var originalGridColor: NSColor?
    private var themeCancellable: AnyCancellable?

    internal init(tableView: NSTableView, family: Family) {
        self.tableView = tableView
        self.family = family
        apply()
        themeCancellable = AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.apply() }
    }

    internal var isBackgroundThemed: Bool {
        backgroundOriginals != nil
    }

    internal func apply() {
        guard let tableView else { return }
        let resolved = ThemeEngine.shared.resolved
        let backgroundSlots = [family.background] + [family.alternateRow].compactMap { $0 }
        applyBackground(to: tableView, themed: backgroundSlots.contains { resolved.isOverridden($0) })
        applyGridColor(to: tableView, themed: family.gridLine.map { resolved.isOverridden($0) } ?? false)
        tableView.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    /// Nil while the theme leaves the background alone, and the row draws AppKit's. A themed table
    /// stripes its rows itself: AppKit's stripes are the system pair whatever the table's color.
    internal func rowBackgroundColor(forRow row: Int) -> NSColor? {
        guard let originals = backgroundOriginals, row >= 0 else { return nil }
        let palette = ThemeEngine.shared.palette
        guard originals.alternates, let alternate = family.alternateRow, !row.isMultiple(of: 2) else {
            return palette[family.background]
        }
        return palette[alternate]
    }

    /// Nil unless the theme sets its own selection, so a default theme keeps AppKit's, which follows
    /// Accent and focus.
    internal func selectionColor(emphasized: Bool) -> NSColor? {
        let resolved = ThemeEngine.shared.resolved
        let slot = family.selection(emphasized: emphasized)
        return resolved.isOverridden(slot) ? resolved[slot] : nil
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
        tableView.backgroundColor = ThemeEngine.shared.palette[family.background]
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
        tableView.gridColor = ThemeEngine.shared.palette[slot]
    }
}

/// The row view of a table `ThemeTableChrome` themes. Each drawing method is AppKit's own unless the
/// theme sets the matching slot.
internal class ThemeTableRowView: NSTableRowView {
    internal weak var chrome: ThemeTableChrome?

    override internal func drawBackground(in dirtyRect: NSRect) {
        guard !isGroupRowStyle,
              let tableView = superview as? NSTableView,
              let fill = chrome?.rowBackgroundColor(forRow: tableView.row(for: self))
        else {
            super.drawBackground(in: dirtyRect)
            return
        }
        fill.setFill()
        dirtyRect.fill()
    }

    /// AppKit's selection recolored rather than replaced, so it keeps the shape the table style gives
    /// it: inset and rounded in an inset table, full width in a plain one.
    override internal func drawSelection(in dirtyRect: NSRect) {
        guard let fill = chrome?.selectionColor(emphasized: isEmphasized),
              let context = NSGraphicsContext.current?.cgContext
        else {
            super.drawSelection(in: dirtyRect)
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        super.drawSelection(in: dirtyRect)
        fill.setFill()
        dirtyRect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A theme picks its selection to sit behind its own text, so the text does not flip to white.
    override internal var interiorBackgroundStyle: NSView.BackgroundStyle {
        guard isSelected, chrome?.selectionColor(emphasized: isEmphasized) != nil else {
            return super.interiorBackgroundStyle
        }
        return .normal
    }
}
