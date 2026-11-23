import SwiftUI

// One entry of an ordered list as one row of its section, since a List nested in a grouped Form does not scroll: its
// title, the file's path under it, an optional value, and its commands in a trailing menu.
struct AdvancedListEntry<Title: View, Value: View>: View {
    let path: String
    let notice: String?
    let actionsLabel: String
    let identifier: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onChangeFile: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let value: () -> Value

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                value()
                actions
            }
        } label: {
            title()
            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if let notice {
                NoticeLabel(notice)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if canMoveUp {
                Button(String(localized: "Move Up")) { onMove(-1) }
            }
            if canMoveDown {
                Button(String(localized: "Move Down")) { onMove(1) }
            }
        }
    }

    private var actions: some View {
        Menu {
            Button(String(localized: "Change File…"), action: onChangeFile)
                .accessibilityIdentifier("\(identifier)-change-file")
            Divider()
            Button(String(localized: "Move Up")) { onMove(-1) }
                .disabled(!canMoveUp)
                .accessibilityIdentifier("\(identifier)-move-up")
            Button(String(localized: "Move Down")) { onMove(1) }
                .disabled(!canMoveDown)
                .accessibilityIdentifier("\(identifier)-move-down")
            Divider()
            Button(String(localized: "Remove"), role: .destructive, action: onRemove)
                .accessibilityIdentifier("\(identifier)-remove")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Actions"))
        .accessibilityLabel(actionsLabel)
        .accessibilityIdentifier("\(identifier)-actions")
    }
}
