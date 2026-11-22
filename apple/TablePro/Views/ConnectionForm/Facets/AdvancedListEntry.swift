import SwiftUI

// A List nested in a grouped Form does not scroll, so each entry of an ordered list is a row of its section.
struct AdvancedListEntry<Primary: View, Secondary: View>: View {
    let primaryTitle: String
    let secondaryTitle: String
    let notice: String?
    let actionsLabel: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(verbatim: primaryTitle)
                    .gridColumnAlignment(.trailing)
                primary()
                actions
            }
            GridRow {
                Text(verbatim: secondaryTitle)
                secondary()
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            if let notice {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    NoticeLabel(notice)
                        .gridCellColumns(2)
                }
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
            Button(String(localized: "Move Up")) { onMove(-1) }
                .disabled(!canMoveUp)
            Button(String(localized: "Move Down")) { onMove(1) }
                .disabled(!canMoveDown)
            Divider()
            Button(String(localized: "Remove"), action: onRemove)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(actionsLabel)
    }
}
