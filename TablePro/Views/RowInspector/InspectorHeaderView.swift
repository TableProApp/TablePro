//
//  InspectorHeaderView.swift
//  TablePro
//

import SwiftUI

/// The inspector's title bar: what is being inspected, and which rendering of it is showing.
///
/// The pane carried no title at all before, because it multiplexed three unrelated surfaces and
/// there was nothing one title could name. `NSSplitViewItemAccessoryViewController` is the
/// sanctioned host for a pane header and is macOS 26 only, so at a macOS 14 target this is drawn
/// by hand above the content.
internal struct InspectorHeaderView: View {
    internal let subject: InspectorSubject
    @Binding internal var viewMode: InspectorViewMode
    internal let showsViewModePicker: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            Spacer(minLength: 6)
            if showsViewModePicker {
                viewModePicker
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both segments are renderings of the same selection, which is the case Apple's inspector
    /// guidance covers. The assistant used to be a third segment here, which is exactly what this
    /// control must not be: a chat is not a view of the selected row.
    private var viewModePicker: some View {
        Picker("", selection: $viewMode) {
            ForEach(InspectorViewMode.allCases, id: \.self) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel(String(localized: "Inspector View"))
    }
}
