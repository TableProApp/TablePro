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
    let actionSystemImage: String?
    let action: (() -> Void)?
    let secondaryActionTitle: String?
    let secondaryActionSystemImage: String?
    let secondaryAction: (() -> Void)?
    let footerText: String?

    init(
        icon: String,
        title: String,
        description: String? = nil,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        action: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        secondaryActionSystemImage: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        footerText: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.action = action
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryActionSystemImage = secondaryActionSystemImage
        self.secondaryAction = secondaryAction
        self.footerText = footerText
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let description {
                Text(description)
            }
        } actions: {
            VStack(spacing: 6) {
                if let actionTitle, let action {
                    Button(action: action) {
                        primaryButtonLabel(title: actionTitle)
                    }
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        secondaryButtonLabel(title: secondaryActionTitle)
                    }
                    .buttonStyle(.borderless)
                }
                if let footerText {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButtonLabel(title: String) -> some View {
        if let actionSystemImage {
            Label(title, systemImage: actionSystemImage)
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func secondaryButtonLabel(title: String) -> some View {
        if let secondaryActionSystemImage {
            Label(title, systemImage: secondaryActionSystemImage)
        } else {
            Text(title)
        }
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
            icon: "list.bullet",
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
