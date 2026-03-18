//
//  ImportProgressView.swift
//  TablePro
//
//  Progress dialog shown during import.
//

import SwiftUI

struct ImportProgressView: View {
    let processedStatements: Int
    let estimatedTotalStatements: Int
    let statusMessage: String
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Importing...")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 8) {
                HStack {
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Executed \(processedStatements) statements")
                            .font(.system(size: 13))

                        Spacer()
                    }
                }

                if !statusMessage.isEmpty {
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
        guard estimatedTotalStatements > 0 else { return 0 }
        return min(1.0, Double(processedStatements) / Double(estimatedTotalStatements))
    }
}
