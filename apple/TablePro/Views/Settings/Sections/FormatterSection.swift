import AppKit
import os
import SwiftUI
import TableProAutocomplete
import UniformTypeIdentifiers

struct SQLFormattingPage: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFormattingPage")
    static let indentWidths = [2, 4, 8]
    static let lineWidths = [80, 100, 120]

    enum IndentWidthChoice: Hashable {
        case editor
        case fixed(Int)

        init(_ settings: SQLFormatterSettings) {
            self = settings.indentFollowsTabWidth ? .editor : .fixed(settings.rules.indentWidth)
        }

        // One whole-value write, so the follow flag and the width never land separately.
        func applied(to settings: SQLFormatterSettings) -> SQLFormatterSettings {
            var updated = settings
            switch self {
            case .editor:
                updated.indentFollowsTabWidth = true
            case .fixed(let width):
                updated.indentFollowsTabWidth = false
                updated.rules.indentWidth = width
            }
            return updated
        }
    }

    enum KeywordCaseChoice: Hashable {
        case editor
        case fixed(SQLFormatterCase)

        init(_ settings: SQLFormatterSettings) {
            self = settings.keywordCaseFollowsEditor ? .editor : .fixed(settings.rules.keywordCase)
        }

        func applied(to settings: SQLFormatterSettings) -> SQLFormatterSettings {
            var updated = settings
            switch self {
            case .editor:
                updated.keywordCaseFollowsEditor = true
            case .fixed(let formatterCase):
                updated.keywordCaseFollowsEditor = false
                updated.rules.keywordCase = formatterCase
            }
            return updated
        }
    }

    @Binding var settings: SQLFormatterSettings
    let editor: EditorSettings
    let font: NSFont

    @State private var isImporting = false
    @State private var exportDocument: SQLFormatterRulesDocument?
    @State private var importError: String?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                FormatterPreview(options: settings.options(for: editor), font: font)
                    .equatable()
            }

            Section {
                Picker("Indent with", selection: $settings.rules.indentStyle) {
                    Text("Spaces").tag(SQLFormatterIndentStyle.spaces)
                    Text("Tabs").tag(SQLFormatterIndentStyle.tabs)
                }
                .accessibilityIdentifier("formatter-indent-style")
                indentWidthPicker
            } header: {
                Text("Indentation")
            }

            Section {
                keywordCasePicker
                Picker("Functions", selection: $settings.rules.functionCase) {
                    caseItems
                }
                .accessibilityIdentifier("formatter-function-case")
                Picker(selection: $settings.rules.dataTypeCase) {
                    caseItems
                } label: {
                    Text("Data types")
                    Text("Engines that match function and type names by exact case, such as ClickHouse, keep the case you typed.")
                }
                .accessibilityIdentifier("formatter-data-type-case")
            } header: {
                Text("Case")
            }

            Section {
                lineWidthPicker
                Picker(selection: $settings.rules.clauseItems) {
                    Text("Beside the keyword").tag(SQLFormatterClauseItems.sameLine)
                    Text("Below the keyword").tag(SQLFormatterClauseItems.newLine)
                } label: {
                    Text("Clause items")
                    Text("Where a broken SELECT, SET, WITH, WHERE or HAVING list starts. A single item stays beside its keyword.")
                }
                .accessibilityIdentifier("formatter-clause-items")
                Picker("Commas", selection: $settings.rules.commaPosition) {
                    Text("At the end of the line").tag(SQLFormatterCommaPosition.trailing)
                    Text("At the start of the line").tag(SQLFormatterCommaPosition.leading)
                }
                .accessibilityIdentifier("formatter-commas")
                Picker(selection: $settings.rules.logicalOperatorNewline) {
                    Text("At the start of the line").tag(SQLFormatterLogicalOperatorNewline.before)
                    Text("At the end of the line").tag(SQLFormatterLogicalOperatorNewline.after)
                } label: {
                    Text("AND and OR")
                    Text("Where they go when a WHERE or HAVING condition breaks.")
                }
                .accessibilityIdentifier("formatter-logical-operators")
                Picker("Join condition", selection: $settings.rules.joinCondition) {
                    Text("On its own line").tag(SQLFormatterJoinCondition.newLine)
                    Text("On the JOIN line").tag(SQLFormatterJoinCondition.sameLine)
                }
                .accessibilityIdentifier("formatter-join-condition")
                Toggle(isOn: $settings.rules.alignAliases) {
                    Text("Align column aliases")
                    Text("Lines up the AS of each SELECT item that sits on one line.")
                }
                .accessibilityIdentifier("formatter-align-aliases")
            } header: {
                Text("Line Breaks")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        importButton
                        exportButton
                    }
                } label: {
                    Text("Rules file")
                    Text("A .sql-formatter.json in a linked SQL folder replaces these rules for files opened from that folder.")
                }
            } header: {
                Text("Rules File")
            }

            Section {
                LabeledContent {
                    Button(String(localized: "Restore Defaults")) { settings = .default }
                        .disabled(settings == .default)
                        .accessibilityIdentifier("formatter-restore-defaults")
                } label: {
                    Text("Restore default rules")
                    Text("Returns every rule on this page to its default.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.sqlFormatting.pageIdentifier)
        .alert(
            String(localized: "Couldn't Import Formatter Rules"),
            isPresented: isShowingImportError,
            presenting: importError
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(verbatim: message)
        }
        .alert(
            String(localized: "Couldn't Export Formatter Rules"),
            isPresented: isShowingExportError,
            presenting: exportError
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(verbatim: message)
        }
    }

    private var indentWidthPicker: some View {
        let widths = SettingsChoices.options(Self.indentWidths, including: settings.rules.indentWidth)
        return Picker("Indent width", selection: indentWidthChoice) {
            Text("Same as editor (\(editor.clampedTabWidth))").tag(IndentWidthChoice.editor)
            Divider()
            ForEach(widths.fixed, id: \.self) { width in
                indentWidthTitle(width).tag(IndentWidthChoice.fixed(width))
            }
            if let extra = widths.extra {
                Divider()
                indentWidthTitle(extra).tag(IndentWidthChoice.fixed(extra))
            }
        }
        .accessibilityIdentifier("formatter-indent-width")
    }

    // A tab counts as indent width columns when a line's width is measured.
    private func indentWidthTitle(_ width: Int) -> Text {
        settings.rules.indentStyle == .tabs
            ? Text("^[\(width) column](inflect: true)")
            : Text("^[\(width) space](inflect: true)")
    }

    private var keywordCasePicker: some View {
        Picker("Keywords", selection: keywordCaseChoice) {
            Text("Same as editor (\(Self.caseName(editorKeywordCase)))").tag(KeywordCaseChoice.editor)
            Divider()
            ForEach(SQLFormatterCase.allCases, id: \.self) { formatterCase in
                Text(verbatim: Self.caseName(formatterCase)).tag(KeywordCaseChoice.fixed(formatterCase))
            }
        }
        .accessibilityIdentifier("formatter-keyword-case")
    }

    private var caseItems: some View {
        ForEach(SQLFormatterCase.allCases, id: \.self) { formatterCase in
            Text(verbatim: Self.caseName(formatterCase)).tag(formatterCase)
        }
    }

    private var lineWidthPicker: some View {
        let widths = Self.lineWidthOptions(including: settings.rules.lineWidth)
        return Picker(selection: $settings.rules.lineWidth) {
            Text("One item per line").tag(0)
            Divider()
            ForEach(widths.fixed, id: \.self) { width in
                Text("^[\(width) character](inflect: true)").tag(width)
            }
            if let extra = widths.extra {
                Divider()
                Text("^[\(extra) character](inflect: true)").tag(extra)
            }
        } label: {
            Text("Line width")
            Text("A SELECT list, SET list or WHERE condition that fits stays on one line.")
        }
        .accessibilityIdentifier("formatter-line-width")
    }

    private var importButton: some View {
        Button(String(localized: "Import…")) { isImporting = true }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importRules(result)
            }
            .accessibilityIdentifier("formatter-import")
    }

    private var exportButton: some View {
        Button(String(localized: "Export…")) { exportRules() }
            .fileExporter(
                isPresented: isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: SQLFormatterRulesFile.exportFileName
            ) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    reportExportFailure(error)
                }
            }
            .accessibilityIdentifier("formatter-export")
    }

    private var indentWidthChoice: Binding<IndentWidthChoice> {
        Binding(
            get: { IndentWidthChoice(settings) },
            set: { settings = $0.applied(to: settings) }
        )
    }

    private var keywordCaseChoice: Binding<KeywordCaseChoice> {
        Binding(
            get: { KeywordCaseChoice(settings) },
            set: { settings = $0.applied(to: settings) }
        )
    }

    private var isExporting: Binding<Bool> {
        Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } })
    }

    private var isShowingImportError: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var isShowingExportError: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func importRules(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            settings = SQLFormatterSettings(imported: try SQLFormatterRulesFile.load(from: url))
        } catch {
            Self.logger.error("Formatter rules import failed: \(error.publicLogShape, privacy: .public)")
            importError = error.localizedDescription
        }
    }

    // The resolved rules, so the file formats alike on a Mac whose tab width or keyword case differs.
    private func exportRules() {
        do {
            exportDocument = SQLFormatterRulesDocument(data: try SQLFormatterRulesFile.encode(settings.options(for: editor)))
        } catch {
            reportExportFailure(error)
        }
    }

    private func reportExportFailure(_ error: Error) {
        Self.logger.error("Formatter rules export failed: \(error.publicLogShape, privacy: .public)")
        exportError = error.localizedDescription
    }

    private var editorKeywordCase: SQLFormatterCase {
        editor.keywordCase.prefersUppercase ? .upper : .lower
    }

    static func caseName(_ formatterCase: SQLFormatterCase) -> String {
        switch formatterCase {
        case .upper: return String(localized: "UPPERCASE")
        case .lower: return String(localized: "lowercase")
        case .preserve: return String(localized: "As written")
        }
    }

    // 0 is "One item per line", listed on its own above the widths.
    static func lineWidthOptions(including current: Int) -> (fixed: [Int], extra: Int?) {
        current == 0 ? (lineWidths, nil) : SettingsChoices.options(lineWidths, including: current)
    }
}

// Formats the sample only when its options or font change; other writes and theme ticks skip the body.
struct FormatterPreview: View, Equatable {
    static let maxLines = 12
    static let sampleSQL = """
        select u.id as user_id, u.name as user_name, count(o.id) as order_count \
        from users u left join orders o on u.id = o.user_id \
        where u.status = 'active' and cast(o.created_at as date) >= '2026-01-01' \
        group by u.id, u.name order by order_count desc;
        """

    let options: SQLFormatterOptions
    let font: NSFont

    static func == (lhs: FormatterPreview, rhs: FormatterPreview) -> Bool {
        lhs.options == rhs.options && lhs.font == rhs.font
    }

    // Unwrapped, since a wrapped preview would hide the line breaks the line width decides.
    var body: some View {
        let text = Self.formattedSample(options: options)
        HighlightedSQLTextView(
            sql: text,
            databaseType: .mysql,
            accessibilityIdentifier: "formatter-preview",
            accessibilityLabel: String(localized: "Formatted preview"),
            lineLayout: .unwrapped
        )
        .frame(height: Self.height(lineCount: Self.lineCount(of: text), font: font))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    static func formattedSample(options: SQLFormatterOptions) -> String {
        let formatted = try? SQLFormatterService().format(sampleSQL, dialect: .mysql, options: options)
        return formatted?.formattedSQL ?? sampleSQL
    }

    static func lineCount(of text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func height(lineCount: Int, font: NSFont) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return CGFloat(min(max(lineCount, 1), maxLines)) * lineHeight + chromeHeight
    }

    // The text view's top and bottom inset, plus a legacy horizontal scroller when one takes room.
    static var chromeHeight: CGFloat {
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        return 24 + scroller
    }
}

struct SQLFormatterRulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
