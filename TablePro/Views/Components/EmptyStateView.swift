//
//  EmptyStateView.swift
//  TablePro
//
//  Reusable empty state component for professional, clean empty states.
//  Used throughout the app when lists or sections have no content.
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        description: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.sm) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.huge))
                .foregroundStyle(ThemeEngine.shared.colors.ui.tertiaryTextSwiftUI)
                .padding(.bottom, ThemeEngine.shared.activeTheme.spacing.xxs)

            // Title
            Text(title)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                .foregroundStyle(ThemeEngine.shared.colors.ui.secondaryTextSwiftUI)

            // Description (optional)
            if let description = description {
                Text(description)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(ThemeEngine.shared.colors.ui.tertiaryTextSwiftUI)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action button (optional)
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        Text(actionTitle)
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, ThemeEngine.shared.activeTheme.spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Convenience Initializers

extension EmptyStateView {
    /// Empty state for foreign keys
    static func foreignKeys(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "link",
            title: String(localized: "No Foreign Keys Yet"),
            description: String(localized: "Click + to add a relationship between this table and another"),
            actionTitle: String(localized: "Add Foreign Key"),
            action: onAdd
        )
    }

    /// Empty state for indexes
    static func indexes(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "list.bullet.indent",
            title: String(localized: "No Indexes Defined"),
            description: String(localized: "Add indexes to improve query performance on frequently searched columns"),
            actionTitle: String(localized: "Add Index"),
            action: onAdd
        )
    }

    /// Empty state for check constraints
    static func checkConstraints(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.shield",
            title: String(localized: "No Check Constraints"),
            description: String(localized: "Add validation rules to ensure data integrity"),
            actionTitle: String(localized: "Add Check Constraint"),
            action: onAdd
        )
    }

    /// Empty state for columns
    static func columns(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "tablecells",
            title: String(localized: "No Columns Defined"),
            description: String(localized: "Every table needs at least one column. Click + to get started"),
            actionTitle: String(localized: "Add Column"),
            action: onAdd
        )
    }
}
