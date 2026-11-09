//
//  FilterRowLayoutTests.swift
//  TableProTests
//
//  Filter rows line up as a grid: every row spans its pane, its value starts at the same x whatever
//  the operator, and its height does not depend on the control holding the value.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct FilterRowLayoutTests {
    private static let columns = ["id", "title", "status", "a_rather_long_column_name_for_the_cap"]
    private static let enumValues = ["status": ["open", "pending", "closed"]]

    private func row(_ filter: TableFilter, focusedId: Binding<UUID?> = .constant(nil)) -> FilterRowView {
        FilterRowView(
            filter: .constant(filter),
            columns: Self.columns,
            completions: [],
            caseMatching: .inMemory,
            enumValuesByColumn: Self.enumValues,
            onAdd: {},
            onDuplicate: {},
            onRemove: {},
            onApply: {},
            onSubmit: {},
            onCancel: {},
            isReorderEnabled: true,
            canMoveUp: false,
            canMoveDown: false,
            onMoveUp: {},
            onMoveDown: {},
            onDropFilter: { _ in },
            focusedFilterId: focusedId
        )
    }

    private static let textEquals = TableFilter(columnName: "title", filterOperator: .equal, value: "a")
    private static let textContains = TableFilter(columnName: "title", filterOperator: .notContains, value: "a")
    private static let enumEquals = TableFilter(columnName: "status", filterOperator: .equal, value: "open")
    private static let between = TableFilter(columnName: "id", filterOperator: .between, value: "1", secondValue: "3")
    private static let isNull = TableFilter(columnName: "title", filterOperator: .isNull)

    @Test("A row whose value is a pop-up spans its pane instead of being centred", arguments: [700, 500] as [CGFloat])
    func popUpRowSpansThePane(width: CGFloat) {
        for filter in [Self.enumEquals, Self.isNull, Self.textEquals] {
            let frame = measureFrame(of: row(filter), width: width)
            #expect(frame.minX == 0, "\(filter.filterOperator) row placed at \(frame.minX)")
            #expect(frame.width == width, "\(filter.filterOperator) row is \(frame.width)pt in a \(width)pt pane")
        }
    }

    @Test("Every row is the same height whatever control holds its value")
    func rowsShareOneHeight() {
        let heights = [Self.textEquals, Self.enumEquals, Self.isNull, Self.between]
            .map { measureFrame(of: row($0), width: 700).height }
        #expect(Set(heights).count == 1, "row heights \(heights)")
    }

    @Test("The value starts at the same x whatever the operator", arguments: [700, 520] as [CGFloat])
    func valuesShareOneColumn(width: CGFloat) throws {
        let starts = try [Self.textEquals, Self.textContains, Self.between].map { filter in
            try #require(valueFields(in: row(filter), width: width).first).minX
        }
        #expect(Set(starts).count == 1, "value fields start at \(starts)")
    }

    @Test("A raw condition starts where the other rows' operator does")
    func rawConditionStartsAtTheOperatorColumn() throws {
        let value = try #require(valueFields(in: row(Self.textEquals), width: 700).first).minX
        let raw = try #require(valueFields(in: row(TableFilter.rawCondition("id = 1")), width: 700).first).minX
        let operatorStart = value - FilterControlMetrics.operatorWidth(reservesCaseIndicator: true) - FilterRowView.spacing
        #expect(raw == operatorStart, "a raw condition starts at \(raw), the operator column at \(operatorStart)")
    }

    @Test("A row never grows past the pane at the pane's narrowest")
    func rowFitsTheNarrowestPane() {
        let width = MainSplitViewController.defaultDetailMinThickness
        let longColumn = TableFilter(columnName: Self.columns[3], filterOperator: .between, value: "1", secondValue: "3")
        let rowHeight = measureFrame(of: row(Self.textEquals), width: 700).height
        for filter in [Self.textContains, Self.between, Self.enumEquals, longColumn] {
            let frame = measureFrame(of: row(filter), width: width)
            #expect(frame.width <= width, "\(filter.columnName) \(filter.filterOperator) row is \(frame.width)pt in \(width)pt")
            #expect(frame.minX >= 0)
            #expect(frame.height == rowHeight, "\(filter.filterOperator) row is \(frame.height)pt tall at \(width)pt")
        }
    }

    @Test("Both Between fields are the same field, sharing the value column's width")
    func betweenFieldsMatch() {
        let fields = valueFields(in: row(Self.between), width: 700)
        #expect(fields.count == 2)
        guard fields.count == 2 else { return }
        #expect(abs(fields[0].width - fields[1].width) <= 1, "Between fields \(fields[0].width) and \(fields[1].width)")
        #expect(fields[0].height == fields[1].height)
    }

    @Test("Focusing one Between field never hands focus to the other")
    func betweenFieldsKeepTheirOwnFocus() throws {
        let focus = FocusBox(Self.between.id)
        let binding = Binding(get: { focus.id }, set: { focus.id = $0 })
        let host = hosted(row(Self.between, focusedId: binding), width: 700)
        defer { host.window?.orderOut(nil) }
        let rerender = {
            host.rootView = AnyView(self.row(Self.between, focusedId: binding).frame(width: 700))
            host.layoutSubtreeIfNeeded()
        }
        rerender()
        let fields = editableFields(in: host).sorted { $0.frame(in: host).minX < $1.frame(in: host).minX }
        try #require(fields.count == 2)
        #expect(firstResponderField(in: host) === fields[0])

        rerender()
        #expect(firstResponderField(in: host) === fields[0], "a second render moved focus off the first field")
    }

    @Test("A row asked to focus its second Between field focuses that one")
    func secondBetweenFieldHasItsOwnIdentity() throws {
        let focus = FocusBox(FilterValueTextField.secondFieldIdentity(for: Self.between.id))
        let binding = Binding(get: { focus.id }, set: { focus.id = $0 })
        let host = hosted(row(Self.between, focusedId: binding), width: 700)
        defer { host.window?.orderOut(nil) }
        host.rootView = AnyView(row(Self.between, focusedId: binding).frame(width: 700))
        host.layoutSubtreeIfNeeded()
        let fields = editableFields(in: host).sorted { $0.frame(in: host).minX < $1.frame(in: host).minX }
        try #require(fields.count == 2)
        #expect(firstResponderField(in: host) === fields[1])
    }

    @Test("Highlight rules line their values up the same way")
    func highlightValuesShareOneColumn() throws {
        let options = HighlightColumnOption.options(for: Self.columns)
        let starts = try [
            HighlightRule(columnName: "title", filterOperator: .equal, value: "a"),
            HighlightRule(columnName: "id", filterOperator: .between, value: "1", secondValue: "3"),
            HighlightRule(columnName: "title", filterOperator: .notContains, value: "a"),
        ].map { rule in
            let view = HighlightRuleRow(
                rule: .constant(rule),
                columnOptions: options,
                focusedRuleID: .constant(nil),
                canMoveUp: false,
                canMoveDown: false,
                onMoveUp: {},
                onMoveDown: {},
                onRemove: {},
                onCancel: {}
            )
            return try #require(valueFields(in: view, width: 523).first).minX
        }
        #expect(Set(starts).count == 1, "rule values start at \(starts)")
    }

    @Test("A long raw condition wraps onto more lines instead of hiding past the first")
    func rawConditionGrowsWithItsText() throws {
        let condition = "status = 'active' AND created_at >= '2024-01-01' AND (owner_id IN (1, 2, 3) OR team = 'core')"
        let raw = TableFilter.rawCondition(condition)
        let field = try #require(valueFields(in: row(raw), width: 420).first)
        #expect(field.height > FilterValueTextField.singleLineHeight(for: .small) + 1, "raw field is \(field.height)pt tall")
    }

    @Test("The operator slot fits every operator's pull-down as SwiftUI draws it")
    func operatorSlotFitsEveryOperator() {
        let slot = FilterControlMetrics.operatorWidth(reservesCaseIndicator: false)
        for op in FilterOperator.allCases {
            let menu = Menu { Button("x") {} } label: { Text(op.displayName) }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            let drawn = NSHostingView(rootView: menu).fittingSize.width
            #expect(drawn <= slot, "\(op.displayName) draws \(drawn)pt in a \(slot)pt slot")
        }
        #expect(FilterControlMetrics.operatorWidth(reservesCaseIndicator: true) > slot)
    }

    @Test("A drifted column lines its row up with the others instead of widening its pop-up")
    func driftedColumnKeepsTheGrid() throws {
        let drifted = TableFilter(columnName: "a_column_this_table_no_longer_has_at_all", filterOperator: .equal, value: "a")
        let starts = try [Self.textEquals, drifted].map { filter in
            try #require(valueFields(in: row(filter), width: 700).first).minX
        }
        #expect(starts[0] == starts[1], "value fields start at \(starts)")
    }

    @Test("Rows on an array path, a badged operator and a plain row line up and fit", arguments: [800, 400] as [CGFloat])
    func elementScopeSlotKeepsTheGrid(width: CGFloat) throws {
        // MongoDB reports array members two levels down, which also brings the nested path button.
        let paths = [PluginFieldPath(path: "orders.items.sku", typeName: "string", depth: 2, arrayPrefixes: ["orders.items"])]
        let scoped = TableFilter(columnName: "orders.items.sku", filterOperator: .equal, value: "a")
        let badged = TableFilter(columnName: "title", filterOperator: .contains, value: "a", isCaseSensitive: true)
        let starts = try [scoped, badged, Self.textEquals].map { filter in
            let view = FilterRowView(
                filter: .constant(filter),
                columns: Self.columns,
                completions: [],
                caseMatching: .inMemory,
                columnMenu: FilterColumnMenu.build(columns: Self.columns, fieldPaths: paths),
                fieldPaths: paths,
                reservesElementScope: true,
                onAdd: {},
                onDuplicate: {},
                onRemove: {},
                onApply: {},
                onSubmit: {},
                onCancel: {},
                isReorderEnabled: true,
                canMoveUp: false,
                canMoveDown: false,
                onMoveUp: {},
                onMoveDown: {},
                onDropFilter: { _ in },
                focusedFilterId: .constant(nil)
            )
            #expect(measureFrame(of: view, width: width).width <= width)
            return try #require(valueFields(in: view, width: width).first).minX
        }
        #expect(Set(starts).count == 1, "value fields start at \(starts)")
    }

    @Test("A pop-up keeps its ideal width and shrinks only when squeezed")
    func idealWidthCapKeepsTheIdealWidth() {
        func width(_ text: String, proposal: CGFloat) -> CGFloat {
            let box = FrameBox()
            let host = NSHostingView(rootView: IdealWidthCap { Text(text).lineLimit(1) }
                .overlay(FrameProbe(box: box))
                .frame(width: proposal, alignment: .leading))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
            host.layoutSubtreeIfNeeded()
            return box.frame?.width ?? .nan
        }
        let ideal = NSHostingView(rootView: Text("pending")).fittingSize.width
        #expect(abs(width("pending", proposal: 400) - ideal) <= 1)
        #expect(width("pending", proposal: 20) <= 20)
    }

    // MARK: - Hosting

    private func hosted(_ content: some View, width: CGFloat) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.frame(width: width)))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func measureFrame(of content: some View, width: CGFloat) -> CGRect {
        let box = FrameBox()
        let host = hosted(VStack(spacing: 0) { content.overlay(FrameProbe(box: box)) }, width: width)
        defer { host.window?.orderOut(nil) }
        return box.frame ?? CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan)
    }

    private func valueFields(in content: some View, width: CGFloat) -> [CGRect] {
        let host = hosted(content, width: width)
        defer { host.window?.orderOut(nil) }
        return editableFields(in: host)
            .map { $0.frame(in: host) }
            .sorted { $0.minX < $1.minX }
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap(editableFields(in:))
    }

    private func firstResponderField(in host: NSView) -> NSTextField? {
        guard let editor = host.window?.firstResponder as? NSTextView else { return nil }
        return editor.delegate as? NSTextField
    }
}

@MainActor
private final class FrameBox {
    var frame: CGRect?
}

@MainActor
private final class FocusBox {
    var id: UUID?

    init(_ id: UUID?) {
        self.id = id
    }
}

private struct FrameProbe: NSViewRepresentable {
    let box: FrameBox

    func makeNSView(context: Context) -> NSView { ProbeView(box: box) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        private let box: FrameBox

        init(box: FrameBox) {
            self.box = box
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("FrameProbe does not support NSCoder init")
        }

        override func layout() {
            super.layout()
            var root: NSView = self
            while let parent = root.superview { root = parent }
            let measured = convert(bounds, to: root)
            MainActor.assumeIsolated { box.frame = measured }
        }
    }
}

private extension NSView {
    func frame(in ancestor: NSView) -> CGRect {
        convert(bounds, to: ancestor)
    }
}
