import SwiftUI

// DatabaseContextRailItemView.swift — one accessible, connection-colored context item
// Part of the Database Context Rail feature (Task 5 of the plan).

struct DatabaseContextRailItemView: View {
    let descriptor: WorkspaceContextDescriptor
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: descriptor.databaseType.iconName)
                .foregroundStyle(descriptor.connectionColor.color)
                .font(.title2)

            Text(descriptor.displayName)
                .lineLimit(2)
                .font(.body)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close context \(descriptor.fullPath)")
        }
        .padding(8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(descriptor.fullPath), database type \(descriptor.databaseType)")
    }
}
