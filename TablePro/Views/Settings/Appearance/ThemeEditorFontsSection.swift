import AppKit
import SwiftUI

struct ThemeEditorFontsSection: View {
    var onThemeDuplicated: ((ThemeDefinition) -> Void)?

    private var engine: ThemeEngine { ThemeEngine.shared }

    @State private var editingTheme: ThemeDefinition?

    private var theme: ThemeDefinition { engine.activeTheme }

    private var currentThemeFonts: ThemeFonts {
        editingTheme?.fonts ?? theme.fonts
    }

    var body: some View {
        Form {
            editorFontSection
            dataGridFontSection
            previewSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: engine.activeTheme.id) {
            editingTheme = nil
        }
    }

    // MARK: - Editor Font

    private var editorFontSection: some View {
        Section(String(localized: "Editor Font")) {
            fontPicker(
                label: String(localized: "Family"),
                selection: currentThemeFonts.editorFontFamily,
                onChange: { newFamily in
                    updateFont { $0.editorFontFamily = newFamily }
                }
            )
            sizePicker(
                label: String(localized: "Size"),
                value: currentThemeFonts.editorFontSize,
                range: 11...18,
                onChange: { newSize in
                    updateFont { $0.editorFontSize = newSize }
                }
            )
        }
    }

    // MARK: - Data Grid Font

    private var dataGridFontSection: some View {
        Section(String(localized: "Data Grid Font")) {
            fontPicker(
                label: String(localized: "Family"),
                selection: currentThemeFonts.dataGridFontFamily,
                onChange: { newFamily in
                    updateFont { $0.dataGridFontFamily = newFamily }
                }
            )
            sizePicker(
                label: String(localized: "Size"),
                value: currentThemeFonts.dataGridFontSize,
                range: 10...18,
                onChange: { newSize in
                    updateFont { $0.dataGridFontSize = newSize }
                }
            )
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section(String(localized: "Preview")) {
            let fonts = currentThemeFonts
            let editorFont = EditorFontResolver.resolve(
                familyId: fonts.editorFontFamily,
                size: CGFloat(fonts.editorFontSize)
            )

            Text("SELECT * FROM users WHERE id = 42;")
                .font(Font(editorFont))
                .foregroundStyle(theme.editor.text.swiftUIColor)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.editor.background.swiftUIColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Helpers

    private func fontPicker(label: String, selection: String, onChange: @escaping (String) -> Void) -> some View {
        Picker(label, selection: Binding<String>(
            get: { selection },
            set: { onChange($0) }
        )) {
            ForEach(EditorFontResolver.availableMonospacedFamilies) { font in
                Text(font.displayName).tag(font.id)
            }
        }
    }

    private func sizePicker(label: String, value: Int, range: ClosedRange<Int>,
                            onChange: @escaping (Int) -> Void) -> some View {
        Picker(label, selection: Binding<Int>(
            get: { value },
            set: { onChange($0) }
        )) {
            ForEach(range, id: \.self) { size in
                Text("\(size) pt").tag(size)
            }
        }
    }

    private func updateFont(_ mutate: (inout ThemeFonts) -> Void) {
        let base = editingTheme ?? theme

        if base.isBuiltIn {
            var copy = engine.duplicateTheme(base, newName: base.name + " (Custom)")
            mutate(&copy.fonts)
            try? engine.saveUserTheme(copy)
            engine.activateTheme(copy)
            editingTheme = copy
            onThemeDuplicated?(copy)
        } else {
            var updated = base
            mutate(&updated.fonts)
            try? engine.saveUserTheme(updated)
            editingTheme = updated
        }
    }
}
