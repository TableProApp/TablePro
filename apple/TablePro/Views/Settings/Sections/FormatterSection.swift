//
//  FormatterSection.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProAutocomplete
import UniformTypeIdentifiers

struct FormatterSection: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "FormatterSection")
    private static let previewMaxLines = 18
    private static let previewSQL = """
        select u.id as user_id, u.name as user_name, count(o.id) as order_count \
        from users u left join orders o on u.id = o.user_id \
        where u.status = 'active' and o.created_at >= '2026-01-01' \
        group by u.id, u.name order by order_count desc;
        """
    private static let indentWidths = [2, 4, 8]
    private static let lineWidths = [0, 80, 100, 120]

    @Binding var settings: SQLFormatterSettings
    let editor: EditorSettings
    @ObservedObject private var themeEngine = ThemeEngine.shared

    @State private var isImporting = false
    @State private var exportDocument: SQLFormatterRulesDocument?
    @State private var importError: String?

    private enum IndentWidthChoice: Hashable {
        case tabWidth
        case fixed(Int)
    }

    private enum KeywordCaseChoice: Hashable {
        case editor
        case fixed(SQLFormatterCase)
    }

    var body: some View {
        Section {
            Picker("Indent with:", selection: $settings.rules.indentStyle) {
                Text("Spaces").tag(SQLFormatterIndentStyle.spaces)
                Text("Tabs").tag(SQLFormatterIndentStyle.tabs)
            }
            Picker("Indent width:", selection: indentWidthChoice) {
                Text(String(format: String(localized: "Tab width (%d)"), editor.clampedTabWidth))
                    .tag(IndentWidthChoice.tabWidth)
                ForEach(Self.options(Self.indentWidths, including: settings.rules.indentWidth), id: \.self) { width in
                    Text(String(format: String(localized: "%d spaces"), width)).tag(IndentWidthChoice.fixed(width))
                }
            }
            Picker("Keyword case:", selection: keywordCaseChoice) {
                Text(String(format: String(localized: "Same as editor (%@)"), caseName(editorKeywordCase)))
                    .tag(KeywordCaseChoice.editor)
                ForEach(SQLFormatterCase.allCases, id: \.self) { formatterCase in
                    Text(caseName(formatterCase)).tag(KeywordCaseChoice.fixed(formatterCase))
                }
            }
            Picker("Function case:", selection: $settings.rules.functionCase) {
                ForEach(SQLFormatterCase.allCases, id: \.self) { formatterCase in
                    Text(caseName(formatterCase)).tag(formatterCase)
                }
            }
            .help(Text("Engines that match function names by exact case, such as ClickHouse, keep the case you typed."))
            Picker("Commas:", selection: $settings.rules.commaPosition) {
                Text("At the end of the line").tag(SQLFormatterCommaPosition.trailing)
                Text("At the start of the line").tag(SQLFormatterCommaPosition.leading)
            }
            Picker("Line width:", selection: $settings.rules.lineWidth) {
                ForEach(Self.options(Self.lineWidths, including: settings.rules.lineWidth), id: \.self) { width in
                    Text(lineWidthName(width)).tag(width)
                }
            }
            .help(Text("A SELECT list, SET list or WHERE condition that fits in this width stays on one line."))
            Picker("Join condition:", selection: $settings.rules.joinCondition) {
                Text("On its own line").tag(SQLFormatterJoinCondition.newLine)
                Text("On the JOIN line").tag(SQLFormatterJoinCondition.sameLine)
            }
            Toggle("Align column aliases", isOn: $settings.rules.alignAliases)

            preview

            LabeledContent("Rules file:") {
                HStack {
                    Button("Import…") { isImporting = true }
                        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                            importRules(result)
                        }
                    Button("Export…") { exportRules() }
                        .fileExporter(
                            isPresented: isExporting,
                            document: exportDocument,
                            contentType: .json,
                            defaultFilename: SQLFormatterRulesFile.exportFileName
                        ) { _ in }
                    Button("Restore Defaults") { settings = .default }
                        .disabled(settings == .default)
                }
            }
        } header: {
            Text("Formatter")
        } footer: {
            Text("A .sql-formatter.json in a linked SQL folder replaces these rules for the files opened from that folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert(
            String(localized: "Couldn't Import Formatter Rules"),
            isPresented: isShowingImportError,
            presenting: importError
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Preview

    private var previewText: String {
        let formatted = try? SQLFormatterService().format(
            Self.previewSQL,
            dialect: .mysql,
            options: settings.options(for: editor)
        )
        return formatted?.formattedSQL ?? Self.previewSQL
    }

    // Unwrapped, since a wrapped preview would hide the line breaks the line width decides.
    private var preview: some View {
        let text = previewText
        let lineCount = min(text.split(separator: "\n", omittingEmptySubsequences: false).count, Self.previewMaxLines)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: themeEngine.editorFonts.font)
        return HighlightedSQLTextView(
            sql: text,
            databaseType: .mysql,
            accessibilityIdentifier: "formatter-preview"
        )
        .frame(height: CGFloat(lineCount) * lineHeight + Self.previewChromeHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // The text view's top and bottom inset, plus a legacy horizontal scroller when one takes room.
    private static var previewChromeHeight: CGFloat {
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        return 24 + scroller
    }

    // MARK: - Bindings

    private var indentWidthChoice: Binding<IndentWidthChoice> {
        Binding(
            get: {
                settings.indentFollowsTabWidth
                    ? .tabWidth
                    : .fixed(settings.rules.indentWidth)
            },
            set: { choice in
                var formatter = settings
                switch choice {
                case .tabWidth:
                    formatter.indentFollowsTabWidth = true
                case .fixed(let width):
                    formatter.indentFollowsTabWidth = false
                    formatter.rules.indentWidth = width
                }
                settings = formatter
            }
        )
    }

    private var keywordCaseChoice: Binding<KeywordCaseChoice> {
        Binding(
            get: {
                settings.keywordCaseFollowsEditor
                    ? .editor
                    : .fixed(settings.rules.keywordCase)
            },
            set: { choice in
                var formatter = settings
                switch choice {
                case .editor:
                    formatter.keywordCaseFollowsEditor = true
                case .fixed(let formatterCase):
                    formatter.keywordCaseFollowsEditor = false
                    formatter.rules.keywordCase = formatterCase
                }
                settings = formatter
            }
        )
    }

    private var isExporting: Binding<Bool> {
        Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } })
    }

    private var isShowingImportError: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    // MARK: - Import and export

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
            Self.logger.error("Formatter rules export failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    // MARK: - Labels

    private var editorKeywordCase: SQLFormatterCase {
        editor.keywordCase.prefersUppercase ? .upper : .lower
    }

    private func caseName(_ formatterCase: SQLFormatterCase) -> String {
        switch formatterCase {
        case .upper: return String(localized: "UPPERCASE")
        case .lower: return String(localized: "lowercase")
        case .preserve: return String(localized: "As written")
        }
    }

    private func lineWidthName(_ width: Int) -> String {
        width == 0
            ? String(localized: "One item per line")
            : String(format: String(localized: "%d characters"), width)
    }

    // A value from an imported file that the picker does not offer still shows as selected.
    private static func options(_ values: [Int], including current: Int) -> [Int] {
        values.contains(current) ? values : (values + [current]).sorted()
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
