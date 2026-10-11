//
//  InspectorSubjectView.swift
//  TablePro
//

import SwiftUI

/// What the inspector is inspecting: the table, and which row of how many.
///
/// It used to share a row with the Fields / JSON control as the inspector's own header. The pane's
/// header is now one view that every surface draws, and a two-line title in it would give the
/// inspector's header a different height from the assistant's, so the subject is the first thing in
/// the inspector's content instead. An empty subject draws nothing rather than a blank line.
internal struct InspectorSubjectView: View {
    internal let subject: InspectorSubject

    internal var body: some View {
        if subject.title != nil || subject.subtitle != nil {
            VStack(alignment: .leading, spacing: 1) {
                if let title = subject.title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)
                }
                if let subtitle = subject.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("inspector-subject-subtitle")
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalInset)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
