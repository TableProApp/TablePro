import os
import SwiftUI

struct RoutineDetailView: View {
    static let logger = Logger(subsystem: "com.TablePro", category: "RoutineDetailView")

    let routineName: String
    let routineType: RoutineInfo.RoutineType
    let connection: DatabaseConnection
    let coordinator: MainContentCoordinator?

    @State var selectedTab: RoutineDetailTab = .definition
    @State var definition: String = ""
    @State var parameters: [RoutineParameterInfo] = []
    @State var ddlStatement: String = ""
    @State var ddlFontSize: CGFloat = 13
    @State var isLoading = true
    @State var errorMessage: String?
    @State var loadedTabs: Set<RoutineDetailTab> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
        }
        .task { await loadInitialData() }
        .onChange(of: selectedTab) { _, newValue in
            Task { await loadTabDataIfNeeded(newValue) }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Spacer()
            Picker("", selection: $selectedTab) {
                ForEach(RoutineDetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            switch selectedTab {
            case .definition:
                DDLTextView(ddl: definition, fontSize: $ddlFontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .parameters:
                parametersTable
            case .ddl:
                DDLTextView(ddl: ddlStatement, fontSize: $ddlFontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Parameters Table

    private var parametersTable: some View {
        Group {
            if parameters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No parameters")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(parameters) {
                    TableColumn("Direction") { param in
                        Text(param.direction)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(directionColor(param.direction))
                    }
                    .width(min: 60, ideal: 80, max: 100)

                    TableColumn("Name") { param in
                        Text(param.name ?? "(unnamed)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(param.name == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 160)

                    TableColumn("Type") { param in
                        Text(param.dataType)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 160)

                    TableColumn("Default") { param in
                        Text(param.defaultValue ?? "")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 120)
                }
            }
        }
    }

    private func directionColor(_ direction: String) -> Color {
        switch direction.uppercased() {
        case "RETURN": .purple
        case "OUT", "INOUT": .orange
        default: .blue
        }
    }
}
