//
//  DataGridViewController+Wrap.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// What the measured rows were measured against. A change in any of it voids every count.
struct DataGridWrapGeometry: Equatable {
    struct Column: Equatable {
        let dataIndex: Int
        let type: ColumnType?
        // The column's rect in the main table, which holds every column at the width both panes draw it.
        let width: CGFloat
        let kind: DataGridCellKind
    }

    let columns: [Column]
    let regular: DataGridWrapLayout.Face
    let medium: DataGridWrapLayout.Face
    let marksInvisibles: Bool
    let isEditable: Bool
    let marksEmptyText: Bool
    let rowHeight: CGFloat
    let lineHeight: CGFloat
}

@MainActor
final class DataGridWrapState {
    var isOn = false
    var geometry: DataGridWrapGeometry?
    // The display rows already measured, and the line-count generation that holds for.
    var measured: (rows: Range<Int>, generation: Int)?
    var isMeasuring = false
    // Rows whose height waits for the field edit in them to end.
    var deferredRows: Set<RowID> = []
}

extension DataGridViewController {
    var wrapsText: Bool { wrapState.isOn }

    var wrapMetrics: DataGridWrapMetrics? {
        guard wrapState.isOn else { return nil }
        return DataGridWrapMetrics(rowHeight: main.tableView.rowHeight, lineHeight: wrapLineHeight)
    }

    private var wrapLineHeight: CGFloat {
        wrapState.geometry?.lineHeight ?? DataGridMetrics.lineHeight(of: ThemeEngine.shared.dataGridFonts.regular)
    }

    // MARK: - Mode

    // AppKit reads which delegate methods exist when the delegate is assigned, so the tables take it again.
    // Returns true when the mode moved, which a full reload has to follow.
    @discardableResult
    func applyWrapMode() -> Bool {
        let wraps = model.wrapsText
        let display = model.display
        if display.keepsLineBreaks != wraps {
            display.keepsLineBreaks = wraps
            display.cache.removeAll()
        }
        presenter.keepsLineBreaks = wraps
        guard wraps != wrapState.isOn else { return false }
        wrapState.isOn = wraps
        wrapState.geometry = nil
        wrapState.measured = nil
        wrapState.deferredRows = []
        display.lineCounts.removeAll()
        answersRowHeights = wraps
        container.anchorsRowsWhenSyncing = wraps
        for pane in panes {
            pane.tableView.delegate = nil
            pane.tableView.delegate = self
        }
        return true
    }

    // The toggle: a reload is the only way the tables take or drop their row heights, so the place is kept by row.
    func wrapModeDidChange() {
        _ = commitCellEditing()
        let table = main.tableView
        var anchor: (rowID: RowID, fraction: CGFloat)?
        if let sample = viewportSample(), let rowID = model.rowID(at: sample.row) {
            anchor = (rowID, sample.offset / max(table.rect(ofRow: sample.row).height, 1))
        }
        applyTableSettings()
        applyWrapMode()
        reloadAll()
        guard let anchor, let row = model.displayIndex(of: anchor.rowID), row < table.numberOfRows else {
            measureViewportRows()
            return
        }
        measureRows(row..<(row + 1), noting: true)
        let rect = table.rect(ofRow: row)
        scrollViewportTop(to: rect.minY + anchor.fraction * rect.height)
        measureViewportRows()
    }

    @objc func toggleWrapText(_ sender: Any?) {
        model.setWrapsText(!model.wrapsText)
    }

    // MARK: - Geometry

    private func makeWrapGeometry() -> DataGridWrapGeometry {
        let table = main.tableView
        let fonts = ThemeEngine.shared.dataGridFonts
        let configuration = model.configuration
        let columns = model.columns
        var measured: [DataGridWrapGeometry.Column] = []
        measured.reserveCapacity(columns.count)
        for (position, column) in columns.columns.enumerated() {
            guard let index = main.tableIndex(forDisplayPosition: position, columns: columns),
                  index < table.numberOfColumns else { continue }
            measured.append(DataGridWrapGeometry.Column(
                dataIndex: column.dataIndex,
                type: column.type,
                width: table.rect(ofColumn: index).width,
                kind: presenter.presentation(forDataIndex: column.dataIndex).kind
            ))
        }
        return DataGridWrapGeometry(
            columns: measured,
            regular: DataGridWrapLayout.Face(fonts.regular),
            medium: DataGridWrapLayout.Face(fonts.medium),
            marksInvisibles: presenter.registry.showsInvisibleCharacters,
            isEditable: configuration.isEditable,
            marksEmptyText: configuration.marksEmptyText,
            rowHeight: table.rowHeight,
            lineHeight: DataGridMetrics.lineHeight(of: fonts.regular)
        )
    }

    // Cheap to ask after anything that can move a width, a font or what a cell draws: nothing happens unless one did.
    @discardableResult
    func syncWrapGeometry(retiles: Bool = true) -> Bool {
        guard wrapState.isOn else { return false }
        let geometry = makeWrapGeometry()
        guard geometry != wrapState.geometry else { return false }
        wrapState.geometry = geometry
        model.display.lineCounts.removeAll()
        if retiles {
            noteAllRowHeights()
        }
        return true
    }

    // MARK: - Measuring

    // The rows AppKit shows or holds ready take their real height before they draw. A row first measured as it
    // enters is measured here, on the main actor: the prewarm is paused for the whole of a live scroll.
    func measureViewportRows() {
        guard wrapState.isOn, !wrapState.isMeasuring else { return }
        wrapState.isMeasuring = true
        defer { wrapState.isMeasuring = false }
        // A row that grows pushes others out and one that was estimated tall lets others in, so the range is read again.
        for _ in 0..<4 {
            let rows = viewportRows()
            let generation = model.display.lineCounts.generation
            if let measured = wrapState.measured, measured.generation == generation,
               measured.rows.lowerBound <= rows.lowerBound, measured.rows.upperBound >= rows.upperBound {
                return
            }
            let grown = measureRows(rows, noting: false)
            wrapState.measured = (rows, model.display.lineCounts.generation)
            guard !grown.isEmpty else { return }
            noteRowHeights(grown)
        }
    }

    private func viewportRows() -> Range<Int> {
        let table = main.tableView
        let count = table.numberOfRows
        guard count > 0 else { return 0..<0 }
        let rows = table.rows(in: table.visibleRect.union(table.preparedContentRect))
        let lower = min(max(rows.location, 0), count)
        return lower..<min(count, max(lower, rows.location + rows.length))
    }

    // Measures the rows that have no count yet and answers the ones taller than the one line the table was told.
    @discardableResult
    private func measureRows(_ range: Range<Int>, noting: Bool) -> IndexSet {
        var grown = IndexSet()
        guard wrapState.isOn, !range.isEmpty else { return grown }
        if wrapState.geometry == nil {
            syncWrapGeometry(retiles: false)
        }
        guard let geometry = wrapState.geometry, let measure = presenter.makeWrapMeasure(geometry) else { return grown }
        let lineCounts = model.display.lineCounts
        let order = model.order
        for index in range {
            guard let row = order.row(at: index, in: measure.rows), lineCounts[row.id] == nil else { continue }
            let lines = presenter.wrapLineCount(of: row, measure: measure)
            lineCounts[row.id] = lines
            if lines > 1 {
                grown.insert(index)
            }
        }
        if noting, !grown.isEmpty {
            noteRowHeights(grown)
        }
        return grown
    }

    func rowHeight(forRow row: Int, in tableView: NSTableView) -> CGFloat {
        let lines = model.rowID(at: row).flatMap { model.display.lineCounts[$0] } ?? 1
        return DataGridMetrics.wrappedRowHeight(lines: lines, rowHeight: tableView.rowHeight, lineHeight: wrapLineHeight)
    }

    // MARK: - Noting heights

    func noteAllRowHeights() {
        let count = main.tableView.numberOfRows
        guard wrapState.isOn, count > 0 else { return }
        noteRowHeights(IndexSet(integersIn: 0..<count))
    }

    func noteRowHeights(ofRowIDs rowIDs: [RowID]) {
        guard wrapState.isOn, !rowIDs.isEmpty else { return }
        noteRowHeights(IndexSet(rowIDs.compactMap { model.displayIndex(of: $0) }))
    }

    // Both panes take the note in one call, and the frozen pane is put back on the main pane's rows after it.
    func noteRowHeights(_ rows: IndexSet) {
        guard wrapState.isOn else { return }
        var rows = rows.intersection(IndexSet(integersIn: 0..<main.tableView.numberOfRows))
        // Whether a height note ends a field edit is not something AppKit documents, so the edited row waits.
        if let edited = editedCell?.row, rows.contains(edited), let rowID = model.rowID(at: edited) {
            rows.remove(edited)
            wrapState.deferredRows.insert(rowID)
        }
        guard !rows.isEmpty else { return }
        keepingViewport(changing: rows) {
            retile(rows)
        }
        container.resyncVertical()
        redrawRows(rows)
        measureViewportRows()
    }

    func noteDeferredRowHeights() {
        guard wrapState.isOn, !wrapState.deferredRows.isEmpty, editedCell == nil else { return }
        let rowIDs = Array(wrapState.deferredRows)
        wrapState.deferredRows = []
        noteRowHeights(ofRowIDs: rowIDs)
    }

    // The rows on screen are measured first, so the heights the tables read are the final ones.
    private func retile(_ rows: IndexSet) {
        let noted = rows.union(measureRows(viewportRows(), noting: false))
        // A measured height is the row's real one, not a change to show: the rows take it at once, unanimated.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for pane in panes {
                pane.tableView.noteHeightOfRows(withIndexesChanged: noted)
            }
        }
    }

    // A new one-line height moves every row, so the fonts and the counts are read again inside one kept place.
    func applyWrappedRowHeight(_ height: CGFloat) {
        let count = main.tableView.numberOfRows
        let rows = IndexSet(integersIn: 0..<count)
        keepingViewport(changing: rows) {
            for pane in panes {
                pane.tableView.rowHeight = height
            }
            syncWrapGeometry(retiles: false)
            retile(rows)
        }
        container.resyncVertical()
        redrawVisibleRows()
        measureViewportRows()
    }

    // A height change above the viewport moves the rows in it. The first visible row keeps its place on screen; when
    // its own height changes, it keeps the share of itself that was scrolled past, so its first line never leaves.
    private func keepingViewport(changing rows: IndexSet, _ change: () -> Void) {
        let table = main.tableView
        guard table.numberOfRows > 0 else {
            change()
            return
        }
        var visible = table.visibleRect
        visible.origin.y += headerInset
        visible.size.height = max(0, visible.height - headerInset)
        let shown = table.rows(in: visible)
        guard shown.length > 0, shown.location >= 0, shown.location < table.numberOfRows else {
            change()
            return
        }
        let anchor = shown.location
        let before = table.rect(ofRow: anchor)
        let offset = visible.minY - before.minY
        change()
        guard anchor < table.numberOfRows else { return }
        let after = table.rect(ofRow: anchor)
        let kept = offset * after.height / max(before.height, 1)
        let top = after.minY + kept
        guard abs(top - visible.minY) > 0.01 else { return }
        scrollViewportTop(to: top)
    }

    // Past a few hundred rows AppKit places rows on fractions of a point and the clip view snaps to a pixel, so the
    // top is rounded into the row it belongs to: rounded down, the row above would be the first one shown.
    private func scrollViewportTop(to top: CGFloat) {
        let scale = main.tableView.window?.backingScaleFactor ?? 1
        let snapped = (top * scale).rounded(.up) / scale
        let x = main.scrollView.contentView.bounds.origin.x
        main.tableView.scroll(NSPoint(x: x, y: snapped - headerInset))
    }

    // MARK: - Changes

    func wrapDidApply(_ change: DataGridChange) {
        guard wrapState.isOn else { return }
        wrapState.measured = nil
        switch change {
        case .reload, .rowsInserted, .rowsRemoved:
            measureViewportRows()
        case .columnsChanged, .columnMetadataChanged:
            if !syncWrapGeometry() {
                measureViewportRows()
            }
        case .rowsUpdated(let rows, _):
            // The model dropped these rows' text and counts, so the tables hold heights nothing answers any more.
            noteRowHeights(rows)
        case .allRowsRepainted:
            break
        }
    }
}
