//
//  ThemeEditorColorsSection.swift
//  TablePro
//

import AppKit
import os
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
    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditorColorsSection")
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
            optionalColorRow(String(localized: "Window Background"), keyPath: \.ui.windowBackground,
                             fallback: .windowBackgroundColor)
            optionalColorRow(String(localized: "Control Background"), keyPath: \.ui.controlBackground,
                             fallback: .controlBackgroundColor)
            optionalColorRow(String(localized: "Card Background"), keyPath: \.ui.cardBackground,
                             fallback: .controlBackgroundColor)
            optionalColorRow(String(localized: "Border"), keyPath: \.ui.border,
                             fallback: .separatorColor)
            optionalColorRow(String(localized: "Primary Text"), keyPath: \.ui.primaryText,
                             fallback: .labelColor)
            optionalColorRow(String(localized: "Secondary Text"), keyPath: \.ui.secondaryText,
                             fallback: .secondaryLabelColor)
            optionalColorRow(String(localized: "Tertiary Text"), keyPath: \.ui.tertiaryText,
                             fallback: .tertiaryLabelColor)
            optionalColorRow(String(localized: "Selection"), keyPath: \.ui.selectionBackground,
                             fallback: .selectedContentBackgroundColor)
            optionalColorRow(String(localized: "Hover"), keyPath: \.ui.hoverBackground,
                             fallback: .unemphasizedSelectedContentBackgroundColor)
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
            optionalColorRow(String(localized: "Background"), keyPath: \.sidebar.background,
                             fallback: .windowBackgroundColor)
            optionalColorRow(String(localized: "Text"), keyPath: \.sidebar.text,
                             fallback: .labelColor)
            optionalColorRow(String(localized: "Selected Item"), keyPath: \.sidebar.selectedItem,
                             fallback: .selectedContentBackgroundColor)
            optionalColorRow(String(localized: "Hover"), keyPath: \.sidebar.hover,
                             fallback: .unemphasizedSelectedContentBackgroundColor)
            optionalColorRow(String(localized: "Section Header"), keyPath: \.sidebar.sectionHeader,
                             fallback: .secondaryLabelColor)
        }
    }

    // MARK: - Toolbar

    private var toolbarSection: some View {
        Section(String(localized: "Toolbar")) {
            optionalColorRow(String(localized: "Secondary Text"), keyPath: \.toolbar.secondaryText,
                             fallback: .secondaryLabelColor)
            optionalColorRow(String(localized: "Tertiary Text"), keyPath: \.toolbar.tertiaryText,
                             fallback: .tertiaryLabelColor)
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
                do {
                    try engine.saveUserTheme(updated)
                } catch {
                    Self.logger.error("Failed to save theme: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }

    private func optionalColorBinding(
        for keyPath: WritableKeyPath<ThemeDefinition, String?>,
        fallback: NSColor
    ) -> Binding<String> {
        Binding(
            get: {
                if let hex = theme[keyPath: keyPath] {
                    return hex
                }
                return (fallback.usingColorSpace(.sRGB) ?? fallback).hexString
            },
            set: { newValue in
                guard theme.isEditable else { return }
                var updated = theme
                updated[keyPath: keyPath] = newValue
                do {
                    try engine.saveUserTheme(updated)
                } catch {
                    Self.logger.error("Failed to save theme: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }

    @ViewBuilder
    private func optionalColorRow(
        _ label: String,
        keyPath: WritableKeyPath<ThemeDefinition, String?>,
        fallback: NSColor
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                HexColorPicker(label: "", hex: optionalColorBinding(for: keyPath, fallback: fallback))
                if theme[keyPath: keyPath] != nil {
                    Button {
                        guard theme.isEditable else { return }
                        var updated = theme
                        updated[keyPath: keyPath] = nil
                        do {
                            try engine.saveUserTheme(updated)
                        } catch {
                            Self.logger.error("Failed to save theme: \(error.localizedDescription, privacy: .public)")
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Reset to System Default"))
                }
            }
        }
    }
}
