//
//  WelcomeOutlineRows.swift
//  TablePro
//

import SwiftUI

internal struct WelcomeOutlineRow: View {
    let model: WelcomeRowModel

    var body: some View {
        switch model {
        case .section(let title):
            WelcomeSectionHeaderRow(title: title)
        case .group(let group):
            WelcomeGroupRow(model: group)
        case .connection(let connection):
            WelcomeConnectionRow(model: connection)
        case .empty:
            Color.clear
        }
    }
}

internal struct ConnectionTile: View {
    let type: DatabaseType
    let identityColor: ConnectionColor?
    var size: CGFloat = 28

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(fill)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        let image = type.iconImage
            .renderingMode(.template)
            .scaledToFit()
            .font(.system(size: size * 0.5, weight: .medium))
            .frame(width: size * 0.58, height: size * 0.58)
        if identityColor != nil {
            image.foregroundStyle(.white)
        } else {
            image.selectionAwareTint(type.themeColor)
        }
    }

    private var fill: AnyShapeStyle {
        guard let identityColor else { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(identityColor.color)
    }
}

private struct WelcomeSectionHeaderRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct WelcomeGroupRow: View {
    let model: WelcomeGroupRowModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .selectionAwareTint(model.color.isDefault ? .secondary : model.color.color)
                .accessibilityHidden(true)
            Text(model.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(model.connectionCount, format: .number)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
    }
}

internal struct WelcomeConnectionRow: View {
    let model: WelcomeConnectionRowModel

    var body: some View {
        HStack(spacing: 10) {
            ConnectionTile(type: model.type, identityColor: model.identityColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    WelcomeConnectionAccessories(model: model)
                }

                HStack(spacing: 8) {
                    Text(model.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    WelcomeConnectionLabels(model: model)
                }
            }
        }
        .padding(.trailing, 8)
        .help(model.tooltip)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeConnectionAccessories: View {
    let model: WelcomeConnectionRowModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isDriverRejected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .selectionAwareTint(.yellow)
                    .help(String(localized: "Driver plugin not loaded. Open Settings to update."))
                    .accessibilityLabel(String(localized: "Plugin not loaded"))
            }

            if model.isLocalOnly {
                Image(systemName: "icloud.slash")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Local only, not synced to iCloud"))
                    .accessibilityLabel(String(localized: "Local only"))
            }

            WelcomeConnectionStatus(connectionId: model.id)
        }
    }
}

private struct WelcomeConnectionStatus: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    let connectionId: UUID

    var body: some View {
        switch databaseManager.activeSessions[connectionId]?.reportedStatus {
        case .connected:
            Text("Connected")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(Text("Connecting"))
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .selectionAwareTint(.orange)
                .help(message)
                .accessibilityLabel(Text("Connection error"))
        case .disconnected, .none:
            EmptyView()
        }
    }
}

private struct WelcomeConnectionLabels: View {
    let model: WelcomeConnectionRowModel

    var body: some View {
        HStack(spacing: 8) {
            if let group = model.groupLabel {
                ConnectionSymbolLabel(systemName: "folder.fill", label: group)
            }
            ForEach(model.tags, id: \.self) { tag in
                ConnectionSymbolLabel(systemName: "tag.fill", label: tag)
            }
            if model.hiddenTagCount > 0 {
                Text(String(format: String(localized: "+%lld"), Int64(model.hiddenTagCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

internal struct ConnectionSymbolLabel: View {
    let systemName: String
    let label: WelcomeTagLabel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .imageScale(.small)
                .selectionAwareTint(label.color.isDefault ? .secondary : label.color.color)
                .accessibilityHidden(true)
            Text(label.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
