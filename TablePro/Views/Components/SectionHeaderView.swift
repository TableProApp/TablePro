//
//  SectionHeaderView.swift
//  TablePro
//
//  Reusable section header with collapse/expand, count, and action buttons.
//  Provides consistent styling across the app.
//

import SwiftUI

struct SectionHeaderView<Actions: View>: View {
    let title: String
    let icon: String?
    let count: Int?
    let isCollapsible: Bool
    @Binding var isExpanded: Bool
    let actions: () -> Actions

    init(
        title: String,
        icon: String? = nil,
        count: Int? = nil,
        isCollapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true),
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.isCollapsible = isCollapsible
        self._isExpanded = isExpanded
        self.actions = actions
    }

    var body: some View {
        if isCollapsible {
            Button(action: { isExpanded.toggle() }) {
                headerContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: String(localized: "%@, %@"), title, isExpanded ? String(localized: "collapse") : String(localized: "expand")))
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            if isCollapsible {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ThemeEngine.shared.colors.ui.tertiaryTextSwiftUI)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
            }

            if let icon = icon {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(ThemeEngine.shared.colors.ui.secondaryTextSwiftUI)
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ThemeEngine.shared.colors.ui.primaryTextSwiftUI)

            if let count = count {
                Text("(\(count))")
                    .font(.subheadline)
                    .foregroundStyle(ThemeEngine.shared.colors.ui.tertiaryTextSwiftUI)
            }

            Spacer()

            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isCollapsible ?
                ThemeEngine.shared.colors.ui.controlBackgroundSwiftUI.opacity(0.5) :
                Color.clear
        )
        .cornerRadius(6)
        .contentShape(Rectangle())
    }
}

// MARK: - Convenience Initializer (No Actions)

extension SectionHeaderView where Actions == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        count: Int? = nil,
        isCollapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true)
    ) {
        self.init(
            title: title,
            icon: icon,
            count: count,
            isCollapsible: isCollapsible,
            isExpanded: isExpanded
        )               { EmptyView() }
    }
}
