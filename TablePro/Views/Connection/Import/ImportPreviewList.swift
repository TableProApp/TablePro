import SwiftUI
import TableProImport

internal struct ImportPreviewList: View {
    @ObservedObject var review: ImportReview

    var body: some View {
        List {
            Section {
                ForEach(review.preview.connections) { row in
                    ImportConnectionRowView(review: review, row: row)
                }
            } header: {
                Toggle(sources: review.connectionToggles, isOn: \.self) {
                    Text("Connections")
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("import-review-connections-toggle")
            }

            if !review.preview.queries.isEmpty {
                Section {
                    ForEach(review.preview.queries) { row in
                        ImportQueryRowView(review: review, row: row)
                    }
                } header: {
                    let toggles = review.queryToggles
                    Toggle(sources: toggles, isOn: \.self) {
                        Text("Saved Queries")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(toggles.isEmpty)
                    .accessibilityIdentifier("import-review-queries-toggle")
                }
            }
        }
        .listStyle(.inset)
    }
}
