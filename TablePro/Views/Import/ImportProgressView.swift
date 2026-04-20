//
//  ImportProgressView.swift
//  TablePro
//
//  Progress dialog shown during import.
//

import SwiftUI

struct ImportProgressView: View {
    let service: ImportService
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Importing...")
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                HStack {
                    if !service.state.statusMessage.isEmpty {
                        Text(service.state.statusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Executed \(service.state.processedStatements) statements")
                            .font(.body)

                        Spacer()
                    }
                }

                if !service.state.statusMessage.isEmpty {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                }
            }

            Button("Stop") {
                onStop()
            }
            .frame(width: 80)
        }
        .padding(24)
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var progressValue: Double {
        guard service.state.estimatedTotalStatements > 0 else { return 0 }
        return min(1.0, Double(service.state.processedStatements) / Double(service.state.estimatedTotalStatements))
    }
}
