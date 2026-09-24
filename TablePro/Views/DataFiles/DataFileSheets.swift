//
//  DataFileSheets.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProTabular
import TableProTabularIO

enum DataFilePropertyOptions {
    static let delimiters: [(label: String, byte: UInt8)] = [
        (String(localized: "Comma  ,"), 0x2C),
        (String(localized: "Semicolon  ;"), 0x3B),
        (String(localized: "Tab"), 0x09),
        (String(localized: "Pipe  |"), 0x7C),
        (String(localized: "Colon  :"), 0x3A),
        (String(localized: "Space"), 0x20)
    ]

    static let quotes: [(label: String, byte: UInt8)] = [
        (String(localized: "Double Quote  \""), 0x22),
        (String(localized: "Single Quote  '"), 0x27)
    ]

    static let escapesByDoubling = 0
    static let escapesWithBackslash = 1

    static let encodings: [TabularTextEncoding] = TabularTextEncoding.allCases

    static let lineEndings = DelimitedDialect.LineEnding.allCases

    static func dialect(
        base: DelimitedDialect,
        delimiter: UInt8,
        quote: UInt8,
        escapeIndex: Int,
        encoding: TabularTextEncoding,
        lineEnding: DelimitedDialect.LineEnding,
        hasHeaderRow: Bool
    ) -> DelimitedDialect {
        DelimitedDialect(
            delimiter: delimiter,
            quote: quote,
            escape: escapeIndex == escapesWithBackslash ? DelimitedDialect.backslash : quote,
            encoding: encoding,
            lineEnding: lineEnding,
            hasByteOrderMark: encoding == base.encoding ? base.hasByteOrderMark : false,
            hasHeaderRow: hasHeaderRow
        )
    }
}

struct DataFilePropertiesSheet: View {
    private let base: DelimitedDialect
    private let onReload: (DelimitedDialect) -> Void
    private let onCancel: () -> Void

    @State private var delimiter: UInt8
    @State private var quote: UInt8
    @State private var escapeIndex: Int
    @State private var encoding: TabularTextEncoding
    @State private var lineEnding: DelimitedDialect.LineEnding
    @State private var hasHeaderRow: Bool

    init(dialect: DelimitedDialect, onReload: @escaping (DelimitedDialect) -> Void, onCancel: @escaping () -> Void) {
        base = dialect
        self.onReload = onReload
        self.onCancel = onCancel
        _delimiter = State(initialValue: dialect.delimiter)
        _quote = State(initialValue: dialect.quote)
        _escapeIndex = State(initialValue: dialect.escapesByDoubling
            ? DataFilePropertyOptions.escapesByDoubling
            : DataFilePropertyOptions.escapesWithBackslash)
        _encoding = State(initialValue: dialect.encoding)
        _lineEnding = State(initialValue: dialect.lineEnding)
        _hasHeaderRow = State(initialValue: dialect.hasHeaderRow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File Properties").font(.headline)
            Text("Re-read the file with these settings. This discards unsaved changes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Form {
                Picker("Delimiter", selection: $delimiter) {
                    ForEach(DataFilePropertyOptions.delimiters, id: \.byte) { option in
                        Text(option.label).tag(option.byte)
                    }
                }
                Picker("Quote character", selection: $quote) {
                    ForEach(DataFilePropertyOptions.quotes, id: \.byte) { option in
                        Text(option.label).tag(option.byte)
                    }
                }
                Picker("Escape character", selection: $escapeIndex) {
                    Text("Doubled Quote").tag(DataFilePropertyOptions.escapesByDoubling)
                    Text(String(localized: "Backslash  \\")).tag(DataFilePropertyOptions.escapesWithBackslash)
                }
                Picker("Encoding", selection: $encoding) {
                    ForEach(DataFilePropertyOptions.encodings, id: \.self) { option in
                        Text(DataFileEncodingNames.name(for: option)).tag(option)
                    }
                }
                Picker("Line ending", selection: $lineEnding) {
                    ForEach(DataFilePropertyOptions.lineEndings, id: \.self) { option in
                        Text(DataFileDialectDescription.lineEndingName(option)).tag(option)
                    }
                }
                Toggle("First row is a header", isOn: $hasHeaderRow)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reload") {
                    onReload(DataFilePropertyOptions.dialect(
                        base: base,
                        delimiter: delimiter,
                        quote: quote,
                        escapeIndex: escapeIndex,
                        encoding: encoding,
                        lineEnding: lineEnding,
                        hasHeaderRow: hasHeaderRow
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct DataFileDuplicatesSheet: View {
    let columns: [(id: TabularColumnID, name: String)]
    let onRemove: ([TabularColumnID], TabularDuplicateOptions) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<TabularColumnID>
    @State private var ignoresCase = false
    @State private var ignoresWhitespace = false

    init(
        columns: [(id: TabularColumnID, name: String)],
        onRemove: @escaping ([TabularColumnID], TabularDuplicateOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.columns = columns
        self.onRemove = onRemove
        self.onCancel = onCancel
        _selected = State(initialValue: Set(columns.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove Duplicate Rows").font(.headline)
            Text("Keeps the first row of each group of matching rows. Rows hidden by a filter or search are not compared.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Compare these columns:")
            List {
                ForEach(columns, id: \.id) { column in
                    Toggle(column.name, isOn: Binding(
                        get: { selected.contains(column.id) },
                        set: { isOn in
                            if isOn {
                                selected.insert(column.id)
                            } else {
                                selected.remove(column.id)
                            }
                        }
                    ))
                }
            }
            .frame(height: 180)
            HStack {
                Button("Select All") { selected = Set(columns.map(\.id)) }
                Button("Deselect All") { selected.removeAll() }
            }
            .buttonStyle(.link)
            Toggle("Ignore case", isOn: $ignoresCase)
            Toggle("Ignore leading and trailing whitespace", isOn: $ignoresWhitespace)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    onRemove(
                        columns.map(\.id).filter { selected.contains($0) },
                        TabularDuplicateOptions(ignoresCase: ignoresCase, ignoresSurroundingWhitespace: ignoresWhitespace)
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

extension DataFileSplitViewController {
    func presentPropertiesSheet() {
        guard sheetController == nil, let dialect = controller.dialect else { return }
        let sheet = DataFilePropertiesSheet(
            dialect: dialect,
            onReload: { [weak self] newDialect in
                self?.dismissSheet()
                self?.confirmReload(with: newDialect)
            },
            onCancel: { [weak self] in self?.dismissSheet() }
        )
        presentSheet(NSHostingController(rootView: sheet))
    }

    func presentDuplicatesSheet() {
        guard sheetController == nil else { return }
        let columns = zip(controller.columnNames.ids, controller.columnNames.displayNames).map { (id: $0, name: $1) }
        let sheet = DataFileDuplicatesSheet(
            columns: columns,
            onRemove: { [weak self] ids, options in
                self?.dismissSheet()
                self?.controller.removeDuplicateRows(comparing: ids, options: options)
            },
            onCancel: { [weak self] in self?.dismissSheet() }
        )
        presentSheet(NSHostingController(rootView: sheet))
    }

    func presentSheet(_ hosting: NSViewController) {
        sheetController = hosting
        presentAsSheet(hosting)
    }

    func dismissSheet() {
        guard let sheet = sheetController else { return }
        dismiss(sheet)
        sheetController = nil
    }

    private func confirmReload(with dialect: DelimitedDialect) {
        guard dataFileDocument?.isDocumentEdited == true, let window = view.window else {
            dataFileDocument?.reload(with: dialect)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reload with new properties?")
        alert.informativeText = String(localized: "This discards your unsaved changes and re-reads the file with the chosen settings.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.dataFileDocument?.reload(with: dialect)
        }
    }
}
