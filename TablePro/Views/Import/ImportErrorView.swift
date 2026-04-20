//
//  ImportErrorView.swift
//  TablePro
//
//  Error dialog shown when import fails.
//

import SwiftUI
import TableProPluginKit

struct ImportErrorView: View {
    let error: (any Error)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(nsColor: .systemRed))

            VStack(spacing: 6) {
                Text("Import Failed")
                    .font(.title3.weight(.semibold))

                if let pluginError = error as? PluginImportError,
                   case .statementFailed(let statement, let line, let underlyingError) = pluginError
                {
                    Text("Failed at line \(line)")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Statement:")
                                .font(.callout.weight(.medium))
                            Text(statement)
                                .font(.system(.subheadline, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("Error:")
                                .font(.callout.weight(.medium))
                                .padding(.top, 8)
                            Text(underlyingError.localizedDescription)
                                .font(.subheadline)
                                .foregroundStyle(Color(nsColor: .systemRed))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(error?.localizedDescription ?? String(localized: "Unknown error"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Button("Close") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
