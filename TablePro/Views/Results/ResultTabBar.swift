//
//  ResultTabBar.swift
//  TablePro
//
//  Horizontal tab bar for switching between multiple result sets.
//  Only shown when a query produces 2+ result sets.
//

import SwiftUI

struct ResultTabBar: View {
    let resultSets: [ResultSet]
    @Binding var activeResultSetId: UUID?
    var onClose: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(resultSets) { rs in
                    resultTab(rs)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 32)
        .background(.bar)
    }

    private func resultTab(_ rs: ResultSet) -> some View {
        let isActive = rs.id == (activeResultSetId ?? resultSets.last?.id)
        return ResultTab(
            label: rs.label,
            isPinned: rs.isPinned,
            isActive: isActive,
            onActivate: { activeResultSetId = rs.id },
            onClose: rs.isPinned ? nil : { onClose?(rs.id) }
        )
        .contextMenu {
            Button(rs.isPinned ? String(localized: "Unpin") : String(localized: "Pin Result")) {
                onPin?(rs.id)
            }
            Divider()
            Button(String(localized: "Close")) { onClose?(rs.id) }
                .disabled(rs.isPinned)
            Button(String(localized: "Close Others")) {
                for other in resultSets where other.id != rs.id && !other.isPinned {
                    onClose?(other.id)
                }
            }
        }
    }
}

private struct ResultTab: View {
    let label: String
    let isPinned: Bool
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Text(label)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close result tab"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: AnyShapeStyle {
        if isActive {
            AnyShapeStyle(.tint.opacity(0.18))
        } else if isHovering {
            AnyShapeStyle(.quaternary)
        } else {
            AnyShapeStyle(.clear)
        }
    }
}
