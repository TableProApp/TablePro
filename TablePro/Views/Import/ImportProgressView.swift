//
//  ImportProgressView.swift
//  TablePro
//

import SwiftUI

/// How far an import has got, and the one way to stop it.
///
/// Stopping asks first, the way the export and backup sheets do. An import writes rows, so an
/// accidental press is the expensive one of the three: statements already run stay committed.
struct ImportProgressView: View {
    let service: ImportService
    let onStop: () -> Void

    @State private var showStopConfirmation = false

    private var hasEstimate: Bool { service.state.estimatedTotalStatements > 0 }

    var body: some View {
        VStack(spacing: 20) {
            Text("Importing…")
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                HStack {
                    if service.state.statusMessage.isEmpty {
                        Text("Executed \(service.state.processedStatements) ^[statement](inflect: true)")
                            .font(.body)
                    } else {
                        Text(service.state.statusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if service.state.statusMessage.isEmpty, hasEstimate {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            Button("Stop") {
                showStopConfirmation = true
            }
        }
        .padding(24)
        .frame(minWidth: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { showStopConfirmation = true }
        .alert(String(localized: "Stop Import?"), isPresented: $showStopConfirmation) {
            Button(String(localized: "Continue"), role: .cancel) {}
            Button(String(localized: "Stop"), role: .destructive) { onStop() }
        } message: {
            Text("Statements already executed stay committed.")
        }
    }

    private var progressValue: Double {
        guard service.state.estimatedTotalStatements > 0 else { return 0 }
        return min(
            1.0,
            Double(service.state.processedStatements) / Double(service.state.estimatedTotalStatements))
    }
}
