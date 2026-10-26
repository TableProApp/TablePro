//
//  RoutineDebugPanes.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct RoutineDebugVariablesView: View {
    @ObservedObject var controller: RoutineDebugController
    @ObservedObject private var themeEngine = ThemeEngine.shared

    private struct Row: Identifiable {
        let id: Int
        let variable: PluginDebugVariable
    }

    var body: some View {
        RoutineDebugPane(title: String(localized: "Variables")) {
            if rows.isEmpty {
                UnavailableStateView(String(localized: "No Variables"), systemImage: "list.bullet.rectangle")
            } else {
                Table(rows) {
                    TableColumn(String(localized: "Name")) { row in
                        Text(row.variable.name)
                    }
                    .width(min: 60, ideal: 120)
                    TableColumn(String(localized: "Value")) { row in
                        value(of: row.variable)
                            .font(themeEngine.valueFontSwiftUI)
                            .textSelection(.enabled)
                    }
                    .width(min: 80, ideal: 200)
                    TableColumn(String(localized: "Type")) { row in
                        Text(row.variable.typeName ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 100)
                }
            }
        }
    }

    private var rows: [Row] {
        controller.variables.enumerated().map { Row(id: $0.offset, variable: $0.element) }
    }

    // NULL reads the way the grid writes it, so a value means the same thing in both places.
    @ViewBuilder
    private func value(of variable: PluginDebugVariable) -> some View {
        if let value = variable.value {
            Text(value)
        } else {
            Text(AppSettingsManager.shared.dataGrid.nullDisplay)
                .foregroundStyle(.secondary)
        }
    }
}

internal struct RoutineDebugCallStackView: View {
    @ObservedObject var controller: RoutineDebugController

    private struct Row: Identifiable {
        let frame: PluginDebugFrame
        var id: Int { frame.level }
    }

    var body: some View {
        RoutineDebugPane(title: String(localized: "Call Stack")) {
            if controller.frames.isEmpty {
                UnavailableStateView(String(localized: "No Call Stack"), systemImage: "square.stack.3d.up")
            } else {
                // The previous pause's stack stays in view, dimmed, until the new one arrives.
                List(controller.frames.map(Row.init(frame:)), selection: selection) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.frame.location?.unit.displayName ?? String(localized: "Unknown"))
                        if let line = row.frame.location?.line {
                            Text(String(format: String(localized: "Line %d"), line))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .disabled(!controller.stackIsCurrent)
            }
        }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { controller.selectedFrameLevel },
            set: { level in
                guard let level else { return }
                controller.selectFrame(level: level)
            }
        )
    }
}

internal struct RoutineDebugOutputView: View {
    @ObservedObject var controller: RoutineDebugController

    var body: some View {
        RoutineDebugPane(title: String(localized: "Output")) {
            if let grid = controller.resultGrid {
                VStack(spacing: 0) {
                    outputLines
                        .frame(maxHeight: controller.outputLines.isEmpty ? 0 : 120)
                    if !controller.outputLines.isEmpty {
                        Divider()
                    }
                    DataGridView(model: grid.model)
                }
            } else if controller.outputLines.isEmpty {
                UnavailableStateView(String(localized: "No Output"), systemImage: "text.alignleft")
            } else {
                outputLines
            }
        }
    }

    private var outputLines: some View {
        ScrollView {
            Text(controller.outputLines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

// A titled region of the debug tab: a small header over its content, the way Xcode's debug area labels its panes.
internal struct RoutineDebugPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .paneBarBackground()
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
