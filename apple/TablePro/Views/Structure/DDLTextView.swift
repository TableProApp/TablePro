import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit

struct DDLTextView: View {
    @ObservedObject private var editorSettings = AppSettingsManager.shared.editorSlice
    let ddl: String
    @Binding var fontSize: Double
    var databaseType: DatabaseType?

    @State private var text: String
    @State private var editorState = SourceEditorState()
    @State private var editorConfiguration: SourceEditorConfiguration

    init(ddl: String, fontSize: Binding<Double>, databaseType: DatabaseType? = nil) {
        self.ddl = ddl
        self._text = State(wrappedValue: ddl)
        self._fontSize = fontSize
        self.databaseType = databaseType
        self._editorConfiguration = State(wrappedValue: Self.makeConfiguration(fontSize: fontSize.wrappedValue))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: resolvedLanguage,
            configuration: editorConfiguration,
            state: $editorState,
            foldProvider: foldProvider
        )
        .onChange(of: ddl) { newDDL in
            text = newDDL
        }
        .onReceive(AppEvents.shared.themeChanged) { _ in
            editorConfiguration = Self.makeConfiguration(fontSize: fontSize)
        }
        .onChange(of: fontSize) { newSize in
            editorConfiguration = Self.makeConfiguration(fontSize: newSize)
        }
        .onChange(of: editorSettings.value) { _ in
            editorConfiguration = Self.makeConfiguration(fontSize: fontSize)
        }
    }

    private var foldProvider: LineFoldProvider? {
        databaseType.flatMap(FoldProviderResolver.provider(for:))
    }

    private var resolvedLanguage: CodeLanguage {
        if let databaseType {
            return PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage
        }
        return .sql
    }

    private static func makeConfiguration(fontSize: Double) -> SourceEditorConfiguration {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        return SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: font,
                wrapLines: false
            ),
            behavior: .init(
                isEditable: false
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            ),
            peripherals: EditorPeripherals.inline(
                lineNumbers: true,
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled
            )
        )
    }
}
