//
//  UnavailableStateView.swift
//  TablePro
//
//  Stands in for `ContentUnavailableView`, which is macOS 14. The three initialisers
//  mirror the system view's, so the call sites read the same and move back when the
//  deployment target rises.
//

import SwiftUI

internal struct UnavailableStateView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    internal init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    internal var body: some View {
        VStack(spacing: 10) {
            label
                .labelStyle(UnavailableLabelStyle())

            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            actions
                .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

internal extension UnavailableStateView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(label: { SwiftUI.Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { SwiftUI.Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }
}

internal extension UnavailableStateView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    static func search(text: String) -> UnavailableStateView {
        UnavailableStateView(
            String(localized: "No Results"),
            systemImage: "magnifyingglass",
            description: text.isEmpty
                ? nil
                : Text(String(format: String(localized: "No results for \"%@\"."), text))
        )
    }

    static var search: UnavailableStateView {
        UnavailableStateView(String(localized: "No Results"), systemImage: "magnifyingglass")
    }
}

private struct UnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            configuration.title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }
}
