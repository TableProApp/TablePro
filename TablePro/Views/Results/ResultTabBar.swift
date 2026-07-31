//
//  ResultTabBar.swift
//  TablePro
//
//  Horizontal tab bar for switching between result sets.
//  Shown for every query result so a single result can be pinned before the
//  next execution replaces it. Pinned results are never an execution target.
//

import SwiftUI

struct ResultTabBar: View {
    let resultSets: [ResultSet]
    @Binding var activeResultSetId: UUID?
    var onClose: ((UUID) -> Void)?
    var onTogglePin: ((UUID) -> Void)?

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
        ResultTab(
            label: rs.label,
            isPinned: rs.isPinned,
            isActive: rs.id == (activeResultSetId ?? resultSets.last?.id),
            onActivate: { activeResultSetId = rs.id },
            onTogglePin: { onTogglePin?(rs.id) },
            onClose: rs.isPinned ? nil : { onClose?(rs.id) }
        )
        .help(provenance(of: rs))
        .contextMenu { menuItems(for: rs) }
    }

    @ViewBuilder
    private func menuItems(for rs: ResultSet) -> some View {
        Button(rs.isPinned ? String(localized: "Unpin Result") : String(localized: "Pin Result")) {
            onTogglePin?(rs.id)
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

    private func provenance(of rs: ResultSet) -> String {
        if let query = rs.baseQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return Self.truncated(query)
        }
        if let errorMessage = rs.errorMessage {
            return Self.truncated(errorMessage)
        }
        return rs.label
    }

    private static func truncated(_ text: String) -> String {
        let value = text as NSString
        guard value.length > tooltipCharacterLimit else { return text }
        return value.substring(to: tooltipCharacterLimit) + "…"
    }

    private static let tooltipCharacterLimit = 300
}

private struct ResultTab: View {
    let label: String
    let isPinned: Bool
    let isActive: Bool
    let onActivate: () -> Void
    let onTogglePin: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovering = false

    @ViewBuilder
    var body: some View {
        if let onClose {
            annotatedPill.accessibilityAction(named: Text(closeTitle), onClose)
        } else {
            annotatedPill
        }
    }

    private var annotatedPill: some View {
        pill
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .accessibilityAction(named: Text(pinActionTitle), onTogglePin)
    }

    private var pill: some View {
        Button(action: onActivate) {
            HStack(spacing: 4) {
                closeControl
                Text(label)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                pinControl
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("result-tab")
    }

    @ViewBuilder
    private var closeControl: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .opacity(isRevealed ? 1 : 0)
            .help(hint(closeTitle, for: .closeResultTab))
            .accessibilityLabel(closeTitle)
            .accessibilityIdentifier("result-tab-close")
        } else {
            Color.clear
                .frame(width: Self.controlSize, height: Self.controlSize)
                .accessibilityHidden(true)
        }
    }

    private var pinControl: some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption2)
                .foregroundStyle(isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .frame(width: Self.controlSize, height: Self.controlSize)
        .opacity(isPinned || isRevealed ? 1 : 0)
        .help(hint(pinActionTitle, for: .pinResultTab))
        .accessibilityLabel(pinActionTitle)
        .accessibilityIdentifier("result-tab-pin")
    }

    private func hint(_ title: String, for action: ShortcutAction) -> String {
        guard isActive else { return title }
        return AppSettingsManager.shared.keyboard.shortcutHint(title, for: action)
    }

    private var isRevealed: Bool {
        isActive || isHovering
    }

    private var pinActionTitle: String {
        isPinned ? String(localized: "Unpin Result") : String(localized: "Pin Result")
    }

    private var closeTitle: String {
        String(localized: "Close result tab")
    }

    private var accessibilityLabel: String {
        guard isPinned else { return label }
        return String(format: String(localized: "%@, pinned"), label)
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

    private static let controlSize: CGFloat = 12
}
