//
//  ThemeEditorColorsSection.swift
//  TablePro
//

import AppKit
import SwiftUI

// MARK: - HexColorPicker

struct HexColorPicker: View {
    let label: String
    @Binding var hex: String

    var body: some View {
        let colorBinding = Binding<Color>(
            get: { hex.swiftUIColor },
            set: { newColor in
                if let converted = NSColor(newColor).usingColorSpace(.sRGB) {
                    hex = converted.hexString
                }
            }
        )
        ColorPicker(label, selection: colorBinding, supportsOpacity: true)
    }
}

// MARK: - ThemeEditorColorsSection

internal struct ThemeEditorColorsSection: View {
    private var engine: ThemeEngine { ThemeEngine.shared }
    private var theme: ThemeDefinition { engine.activeTheme }

    var body: some View {
        Form {
            editorSection
            syntaxSection
            dataGridSection
            interfaceSection
            statusSection
            badgesSection
            sidebarSection
            toolbarSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Editor

    private var editorSection: some View {
        Section(String(localized: "Editor")) {
            LabeledContent(String(localized: "Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.background))
            }
            LabeledContent(String(localized: "Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.text))
            }
            LabeledContent(String(localized: "Cursor")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.cursor))
            }
            LabeledContent(String(localized: "Current Line")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.currentLineHighlight))
            }
            LabeledContent(String(localized: "Selection")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.selection))
            }
            LabeledContent(String(localized: "Line Number")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.lineNumber))
            }
            LabeledContent(String(localized: "Invisibles")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.invisibles))
            }
        }
    }

    private var syntaxSection: some View {
        Section(String(localized: "Syntax Colors")) {
            LabeledContent(String(localized: "Keyword")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.keyword))
            }
            LabeledContent(String(localized: "String")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.string))
            }
            LabeledContent(String(localized: "Number")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.number))
            }
            LabeledContent(String(localized: "Comment")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.comment))
            }
            LabeledContent(String(localized: "NULL")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.null))
            }
            LabeledContent(String(localized: "Operator")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.operator))
            }
            LabeledContent(String(localized: "Function")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.function))
            }
            LabeledContent(String(localized: "Type")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.editor.syntax.type))
            }
        }
    }

    // MARK: - Data Grid

    private var dataGridSection: some View {
        Section(String(localized: "Data Grid")) {
            LabeledContent(String(localized: "Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.background))
            }
            LabeledContent(String(localized: "Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.text))
            }
            LabeledContent(String(localized: "Alternate Row")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.alternateRow))
            }
            LabeledContent(String(localized: "NULL Value")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.nullValue))
            }
            LabeledContent(String(localized: "Bool True")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.boolTrue))
            }
            LabeledContent(String(localized: "Bool False")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.boolFalse))
            }
            LabeledContent(String(localized: "Row Number")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.rowNumber))
            }
            LabeledContent(String(localized: "Modified")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.modified))
            }
            LabeledContent(String(localized: "Inserted")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.inserted))
            }
            LabeledContent(String(localized: "Deleted")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.deleted))
            }
            LabeledContent(String(localized: "Deleted Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.deletedText))
            }
            LabeledContent(String(localized: "Focus Border")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.dataGrid.focusBorder))
            }
        }
    }

    // MARK: - Interface

    private var interfaceSection: some View {
        Section(String(localized: "Interface")) {
            LabeledContent(String(localized: "Window Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.windowBackground))
            }
            LabeledContent(String(localized: "Control Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.controlBackground))
            }
            LabeledContent(String(localized: "Card Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.cardBackground))
            }
            LabeledContent(String(localized: "Border")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.border))
            }
            LabeledContent(String(localized: "Primary Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.primaryText))
            }
            LabeledContent(String(localized: "Secondary Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.secondaryText))
            }
            LabeledContent(String(localized: "Tertiary Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.tertiaryText))
            }
            LabeledContent(String(localized: "Selection")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.selectionBackground))
            }
            LabeledContent(String(localized: "Hover")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.hoverBackground))
            }
        }
    }

    private var statusSection: some View {
        Section(String(localized: "Status Colors")) {
            LabeledContent(String(localized: "Success")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.status.success))
            }
            LabeledContent(String(localized: "Warning")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.status.warning))
            }
            LabeledContent(String(localized: "Error")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.status.error))
            }
            LabeledContent(String(localized: "Info")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.status.info))
            }
        }
    }

    private var badgesSection: some View {
        Section(String(localized: "Badges")) {
            LabeledContent(String(localized: "Badge Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.badges.background))
            }
            LabeledContent(String(localized: "Primary Key")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.badges.primaryKey))
            }
            LabeledContent(String(localized: "Auto Increment")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.ui.badges.autoIncrement))
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarSection: some View {
        Section(String(localized: "Sidebar")) {
            LabeledContent(String(localized: "Background")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.sidebar.background))
            }
            LabeledContent(String(localized: "Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.sidebar.text))
            }
            LabeledContent(String(localized: "Selected Item")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.sidebar.selectedItem))
            }
            LabeledContent(String(localized: "Hover")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.sidebar.hover))
            }
            LabeledContent(String(localized: "Section Header")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.sidebar.sectionHeader))
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarSection: some View {
        Section(String(localized: "Toolbar")) {
            LabeledContent(String(localized: "Secondary Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.toolbar.secondaryText))
            }
            LabeledContent(String(localized: "Tertiary Text")) {
                HexColorPicker(label: "", hex: colorBinding(for: \.toolbar.tertiaryText))
            }
        }
    }

    // MARK: - Helpers

    private func colorBinding(for keyPath: WritableKeyPath<ThemeDefinition, String>) -> Binding<String> {
        Binding(
            get: { theme[keyPath: keyPath] },
            set: { newValue in
                guard theme.isEditable else { return }
                var updated = theme
                updated[keyPath: keyPath] = newValue
                try? engine.saveUserTheme(updated)
            }
        )
    }
}
