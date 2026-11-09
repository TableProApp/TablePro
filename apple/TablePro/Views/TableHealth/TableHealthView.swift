import SwiftUI

@MainActor
struct TableHealthActions {
    let openTable: (TableHealthFinding) -> Void
    let openInEditor: (String) -> Void
    let saveFixScript: (String) -> Void
    let export: () -> Void
}

struct TableHealthView: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseName: String
    let databaseType: DatabaseType
    let actions: TableHealthActions

    // A VStack, not safeAreaInset: the inset does not reach a List hosted inside the split view.
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSupported, !viewModel.needsDatabase {
                VStack(spacing: 0) {
                    TableHealthPaneBar(
                        viewModel: viewModel,
                        databaseName: databaseName,
                        databaseType: databaseType,
                        actions: actions
                    )
                    Divider()
                }
                .paneBarBackground()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isSupported {
            UnavailableStateView(
                String(localized: "Table Health Not Available"),
                systemImage: "stethoscope",
                description: Text("Table health is available for PostgreSQL, MySQL and MariaDB.")
            )
        } else if viewModel.needsDatabase {
            UnavailableStateView(
                String(localized: "No Database Selected"),
                systemImage: "cylinder",
                description: Text(verbatim: TableHealthError.noDatabase.errorDescription ?? "")
            )
        } else if viewModel.report != nil {
            AutosavingSplitView(
                autosaveName: "com.TablePro.tableHealth.checksFindings",
                primaryMinimum: TableHealthLayoutMetrics.checksListMinimumWidth,
                primaryMaximum: TableHealthLayoutMetrics.checksListMaximumWidth,
                secondaryMinimum: TableHealthLayoutMetrics.findingsMinimumWidth,
                collapsesPrimaryWhenTight: true
            ) {
                TableHealthChecksList(viewModel: viewModel)
            } secondary: {
                AutosavingSplitView(
                    autosaveName: "com.TablePro.tableHealth.findingsDetail",
                    isVertical: false,
                    primaryMinimum: TableHealthLayoutMetrics.findingsMinimumHeight,
                    secondaryMinimum: TableHealthLayoutMetrics.previewMinimumHeight,
                    primaryHoldingPriority: .splitPaneFlexible
                ) {
                    TableHealthFindingsPane(viewModel: viewModel, databaseType: databaseType, actions: actions)
                } secondary: {
                    TableHealthPreviewPane(viewModel: viewModel, databaseType: databaseType, actions: actions)
                }
            }
        } else if let error = viewModel.loadError {
            UnavailableStateView {
                Label(String(localized: "Could Not Read Table Health"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await viewModel.refresh() }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
