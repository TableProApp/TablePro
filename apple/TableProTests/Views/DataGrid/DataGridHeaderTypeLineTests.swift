//
//  DataGridHeaderTypeLineTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridHeaderTypeLineTests {
    // `loose` has no type: the result named three columns and typed two.
    private static func typedRows(rowCount: Int = 5) -> TableRows {
        TableRows.from(
            queryRows: (0..<rowCount).map { [.text("\($0)"), .text("n\($0)"), .text("x")] },
            columns: ["id", "label", "loose"],
            columnTypes: [.integer(rawType: "bigint(20)"), .text(rawType: "character varying(255)")]
        )
    }

    private static func configuration(showsColumnTypes: Bool) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.showsColumnTypes = showsColumnTypes
        return configuration
    }

    private func grid(showsColumnTypes: Bool, rows: TableRows = typedRows()) -> HostedDataGrid {
        HostedDataGrid(rows: rows, configuration: Self.configuration(showsColumnTypes: showsColumnTypes))
    }

    private func setShowsColumnTypes(_ shows: Bool, on grid: HostedDataGrid) {
        grid.model.configuration.showsColumnTypes = shows
        grid.layout()
    }

    private func headerHeights(_ grid: HostedDataGrid) -> [CGFloat] {
        grid.controller.panes.map { $0.headerView.frame.height }
    }

    private func standardHeight() -> CGFloat {
        let plain = grid(showsColumnTypes: false)
        defer { plain.close() }
        return plain.controller.main.headerView.frame.height
    }

    // MARK: - Height

    @Test("The header is one line tall by default and one type line taller with column types, in both panes")
    func headerHeightFollowsTheSetting() {
        let standard = standardHeight()
        let typed = grid(showsColumnTypes: true)
        defer { typed.close() }

        #expect(standard > 0)
        #expect(headerHeights(typed) == [standard + DataGridHeaderTypeLine.lineHeight, standard + DataGridHeaderTypeLine.lineHeight])
        #expect(typed.controller.headerInset == standard + DataGridHeaderTypeLine.lineHeight)
    }

    @Test("Turning column types off restores today's header height and keeps the first row under it")
    func turningTypesOffRestoresTheHeight() throws {
        let standard = standardHeight()
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }

        setShowsColumnTypes(true, on: grid)
        #expect(headerHeights(grid) == [standard + DataGridHeaderTypeLine.lineHeight, standard + DataGridHeaderTypeLine.lineHeight])
        var sample = try #require(grid.controller.viewportSample())
        #expect(sample.row == 0 && sample.offset == 0)

        setShowsColumnTypes(false, on: grid)
        #expect(headerHeights(grid) == [standard, standard])
        #expect(grid.controller.headerInset == standard)
        sample = try #require(grid.controller.viewportSample())
        #expect(sample.row == 0 && sample.offset == 0)
    }

    @Test("A grid scrolled down keeps its first visible row when the header grows")
    func scrolledGridKeepsItsFirstRow() throws {
        let grid = grid(showsColumnTypes: false, rows: Self.typedRows(rowCount: 80))
        defer { grid.close() }
        let table = grid.main
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 30).minY - grid.controller.headerInset))
        #expect(try #require(grid.controller.viewportSample()).row == 30)

        setShowsColumnTypes(true, on: grid)

        let sample = try #require(grid.controller.viewportSample())
        #expect(sample.row == 30)
        #expect(sample.offset == 0)
    }

    // MARK: - Layout

    @Test("With column types the title keeps AppKit's band on top and the type line sits under it, centered together")
    func contentPutsTheTitleOnTop() {
        let grid = grid(showsColumnTypes: true)
        defer { grid.close() }
        let header = grid.controller.main.headerView
        let frame = NSRect(x: 10, y: 0, width: 120, height: header.frame.height)

        let content = header.contentRect(forCellFrame: frame)
        let title = ThemeTableHeaderCell.titleRect(in: content)

        #expect(content.height == ThemeTableHeaderCell.interiorHeight + DataGridHeaderTypeLine.lineHeight)
        #expect(content.midY == frame.midY)
        #expect(title == NSRect(x: 10, y: content.minY, width: 120, height: ThemeTableHeaderCell.interiorHeight))
        #expect(content.maxY - title.maxY == DataGridHeaderTypeLine.lineHeight)
    }

    @Test("Without column types a heading is the one centered band it always was")
    func contentWithoutTypesIsTheBand() {
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }
        let header = grid.controller.main.headerView
        let frame = NSRect(x: 10, y: 0, width: 120, height: header.frame.height)

        let content = header.contentRect(forCellFrame: frame)

        #expect(content == ThemeTableHeaderCell.interiorRect(in: frame))
        #expect(ThemeTableHeaderCell.titleRect(in: content) == content)
    }

    // MARK: - Type line

    @Test("The type line is the engine's spelling with its category, and nothing for an untyped or row-number column")
    func typeLineReadsTheEnginesType() throws {
        let grid = grid(showsColumnTypes: true)
        defer { grid.close() }
        let controller = grid.controller

        let idColumn = try #require(grid.tableColumn(named: "id"))
        let labelColumn = try #require(grid.tableColumn(named: "label"))
        let looseColumn = try #require(grid.tableColumn(named: "loose"))
        let rowNumber = try #require(controller.main.rowNumberTableColumn)

        let id = try #require(controller.headerTypeLine(for: idColumn, in: .main))
        #expect(id.text == "bigint(20)")
        #expect(id.category == .number)
        let label = try #require(controller.headerTypeLine(for: labelColumn, in: .main))
        #expect(label.text == "character varying(255)")
        #expect(label.category == .text)
        #expect(controller.headerTypeLine(for: looseColumn, in: .main) == nil)
        #expect(controller.headerTypeLine(for: rowNumber, in: .main) == nil)
    }

    @Test("No type line is offered while column types are off")
    func noTypeLineWhileOff() throws {
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }

        let column = try #require(grid.tableColumn(named: "id"))

        #expect(grid.controller.headerTypeLine(for: column, in: .main) == nil)
    }

    @Test("A type with no spelling from the engine reads as the app's name for it")
    func typeNameFallsBackToTheDisplayName() {
        #expect(DataGridHeaderTypeLine.typeName(of: .integer(rawType: "int4")) == "int4")
        #expect(DataGridHeaderTypeLine.typeName(of: .integer(rawType: nil)) == "Integer")
        #expect(DataGridHeaderTypeLine.typeName(of: .json(rawType: "  ")) == "JSON")
        #expect(DataGridHeaderTypeLine.typeName(of: nil) == nil)
        #expect(DataGridHeaderTypeLine(nil) == nil)
    }

    @Test("The tooltip keeps the name and type, and VoiceOver hears the type only while the line shows")
    func tooltipAndAccessibilityLabel() throws {
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "id"))

        #expect(column.headerToolTip == "id (bigint(20))")
        #expect(column.headerCell.accessibilityLabel() == String(format: String(localized: "Column: %@"), "id"))

        setShowsColumnTypes(true, on: grid)

        #expect(column.headerToolTip == "id (bigint(20))")
        #expect(column.headerCell.accessibilityLabel() == String(format: String(localized: "Column: %@"), "id") + ", bigint(20)")
    }

    // MARK: - The table's own type

    // MySQL's result set reports `INT` and `DECIMAL`; the table defines `int unsigned` and `decimal(12,2)`. `note` is a
    // column the definition does not name.
    private static func definedRows(declaredTypes: [String: String] = ["id": "int unsigned", "total": "decimal(12,2)"]) -> TableRows {
        TableRows.from(
            queryRows: (0..<5).map { [.text("\($0)"), .text("1.5"), .text("x")] },
            columns: ["id", "total", "note"],
            columnTypes: [.integer(rawType: "INT"), .decimal(rawType: "DECIMAL"), .text(rawType: "VARCHAR")],
            columnDeclaredTypes: declaredTypes
        )
    }

    private func definedGrid(namesDeclaredTypes: Bool, rows: TableRows = definedRows()) -> HostedDataGrid {
        var configuration = Self.configuration(showsColumnTypes: true)
        configuration.namesDeclaredColumnTypes = namesDeclaredTypes
        return HostedDataGrid(rows: rows, configuration: configuration)
    }

    private func typeLine(_ name: String, in grid: HostedDataGrid) throws -> DataGridHeaderTypeLine? {
        grid.controller.headerTypeLine(for: try #require(grid.tableColumn(named: name)), in: .main)
    }

    @Test("A table's data tab names each type as the table defines it, in its casing, and the result's type where it is not defined")
    func typeLineNamesTheTablesDefinition() throws {
        let grid = definedGrid(namesDeclaredTypes: true)
        defer { grid.close() }

        let id = try #require(try typeLine("id", in: grid))
        #expect(id.text == "int unsigned")
        #expect(id.category == .number)
        let total = try #require(try typeLine("total", in: grid))
        #expect(total.text == "decimal(12,2)")
        #expect(total.category == .number)
        #expect(try typeLine("note", in: grid)?.text == "VARCHAR")

        let column = try #require(grid.tableColumn(named: "total"))
        #expect(column.headerCell.accessibilityLabel() == String(format: String(localized: "Column: %@"), "total") + ", decimal(12,2)")
        #expect(column.headerToolTip == "total (DECIMAL)", "the tooltip is unchanged")
    }

    @Test("A grid whose owner does not name the table's types shows the result's type")
    func otherGridsNameTheResultsType() throws {
        let grid = definedGrid(namesDeclaredTypes: false)
        defer { grid.close() }

        #expect(try typeLine("id", in: grid)?.text == "INT")
        #expect(try typeLine("total", in: grid)?.text == "DECIMAL")
    }

    @Test("A definition takes the place of the result's type, and an empty one does not")
    func declaredTypeNameFallsBack() throws {
        #expect(DataGridHeaderTypeLine.typeName(of: .integer(rawType: "INT"), declaredType: "int unsigned") == "int unsigned")
        #expect(DataGridHeaderTypeLine.typeName(of: .integer(rawType: "INT"), declaredType: "  ") == "INT")
        #expect(DataGridHeaderTypeLine.typeName(of: nil, declaredType: nil) == nil)
        let untyped = try #require(DataGridHeaderTypeLine(nil, declaredType: "decimal(12,2)"))
        #expect(untyped.text == "decimal(12,2)")
        #expect(untyped.category == .number)
    }

    @Test("A definition that lands after the rows renames the type line and widens an automatic width to hold it")
    func lateDefinitionWidensTheColumn() throws {
        let grid = definedGrid(namesDeclaredTypes: true, rows: Self.definedRows(declaredTypes: [:]))
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "total"))
        #expect(try typeLine("total", in: grid)?.text == "DECIMAL")
        let before = column.width

        grid.owner.tableRows.updateDisplayMetadata(columnDeclaredTypes: ["total": "decimal(12,2) unsigned zerofill"])
        grid.model.apply(.columnsReplaced)
        grid.layout()

        let line = try #require(try typeLine("total", in: grid))
        #expect(line.text == "decimal(12,2) unsigned zerofill")
        #expect(before < line.width)
        #expect(column.width >= line.width)
    }

    // MARK: - Width

    @Test("An automatic width makes room for a type line wider than the name and the values")
    func automaticWidthHoldsTheTypeLine() throws {
        let rows = Self.typedRows()
        let column = DataGridColumn(
            id: DataGridColumnID(name: "label", occurrence: 0),
            dataIndex: 1,
            type: rows.columnTypes[1],
            comment: nil
        )
        let input = DataGridColumnWidthCalculator.Input(column: column, accessory: .none, displayFormat: nil)
        var calculator = DataGridColumnWidthCalculator(
            rows: rows,
            databaseType: nil,
            nullDisplayString: "NULL",
            revealsInvisibleCharacters: false,
            fonts: ThemeEngine.shared.dataGridFonts
        )
        let without = calculator.automaticWidth(input)
        let line = try #require(DataGridHeaderTypeLine(column.type))

        calculator.showsTypeLine = true
        let with = calculator.automaticWidth(input)

        #expect(line.width > without)
        #expect(with >= line.width)
        #expect(calculator.fittedWidth(input, availableWidth: 1_000) >= line.width)
    }

    @Test("The type line's width counts the glyph, the text and the insets")
    func typeLineWidthCountsItsParts() throws {
        let line = try #require(DataGridHeaderTypeLine(.text(rawType: "character varying(255)")))
        let text = ("character varying(255)" as NSString).size(withAttributes: [.font: DataGridHeaderTypeLine.font]).width
        let glyph = DataGridHeaderTypeLine.glyphWidth(.text)

        #expect(glyph > 0)
        #expect(line.width >= text + glyph + DataGridHeaderTypeLine.glyphSpacing
            + DataGridHeaderTypeLine.leadingInset + DataGridHeaderTypeLine.trailingInset)
    }

    @Test("Turning column types on widens an automatic width to its type line and turning them off narrows it back")
    func togglingMeasuresAutomaticWidthsAgain() throws {
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "label"))
        let before = column.width
        let line = try #require(DataGridHeaderTypeLine(.text(rawType: "character varying(255)")))
        #expect(before < line.width)

        setShowsColumnTypes(true, on: grid)
        #expect(column.width >= line.width)

        setShowsColumnTypes(false, on: grid)
        #expect(column.width == before)
    }

    @Test("A width the user set stays when column types are turned on")
    func userWidthSurvivesTheToggle() throws {
        let grid = grid(showsColumnTypes: false)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "label"))
        column.width = 90
        grid.controller.columnDidResize(column, in: grid.controller.main)

        setShowsColumnTypes(true, on: grid)

        #expect(column.width == 90)
    }

    // MARK: - Drawing

    // Drawn straight into an sRGB bitmap, flipped like the header, so row 0 of the bitmap is the top.
    private func raster(size: NSSize, _ draw: () -> Void) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let aqua = try #require(NSAppearance(named: .aqua))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        aqua.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    // Pixels in the type line's band that are not the header's own fill.
    private func typeLineInk(of name: String, in grid: HostedDataGrid) throws -> Int {
        let header = grid.controller.main.headerView
        let tableColumn = try #require(grid.tableColumn(named: name))
        let index = try #require(grid.main.tableColumns.firstIndex { $0 === tableColumn })
        let cell = try #require(tableColumn.headerCell as? ThemeTableHeaderCell)
        let frame = header.headerRect(ofColumn: index)
        let rep = try raster(size: NSSize(width: frame.maxX.rounded(.up), height: frame.height)) {
            cell.draw(withFrame: frame, in: header)
        }
        let content = header.contentRect(forCellFrame: frame)
        let band = ThemeTableHeaderCell.titleRect(in: content).maxY ..< content.maxY
        let fill = try #require(rep.colorAt(x: Int(frame.minX) + 1, y: 1))
        var ink = 0
        for y in Int(band.lowerBound) ..< Int(band.upperBound) {
            for x in Int(frame.minX) ..< Int(frame.maxX) - 2 {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if !ThemeTestFixture.matches(color, fill, tolerance: 0.05) { ink += 1 }
            }
        }
        return ink
    }

    @Test("A typed column draws its type line under the title and an untyped one leaves the line empty")
    func headerDrawsTheTypeLine() throws {
        let grid = grid(showsColumnTypes: true)
        defer { grid.close() }

        #expect(try typeLineInk(of: "id", in: grid) > 0)
        #expect(try typeLineInk(of: "loose", in: grid) == 0)
    }
}
