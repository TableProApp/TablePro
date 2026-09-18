import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct ConnectionListRow: View {
    @Environment(\.editMode) private var editMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let model: ConnectionListRowModel
    let isRenaming: Bool
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draftName = ""
    @FocusState private var isNameFieldFocused: Bool

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        if isRenaming {
            content
        } else if isEditing {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.accessibilityLabel)
        } else {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    content
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint(Text("Opens this connection"))
        }
    }

    private var lineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }

    private var contentLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var content: some View {
        contentLayout {
            ConnectionTile(type: model.type, color: model.color)

            VStack(alignment: .leading, spacing: 3) {
                title
                Text(model.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                if model.groupLabel != nil || !model.tags.isEmpty {
                    ConnectionRowLabels(model: model, lineLimit: lineLimit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.showsFavoriteMark {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .font(.body)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.words)
                .onSubmit { onCommitRename(draftName) }
                .onKeyPress(.escape) {
                    onCancelRename()
                    return .handled
                }
                .onAppear {
                    draftName = model.title
                    isNameFieldFocused = true
                }
                .onChange(of: isNameFieldFocused) { _, focused in
                    guard !focused else { return }
                    onCommitRename(draftName)
                }
        } else {
            Text(model.title)
                .font(.body)
                .lineLimit(lineLimit)
        }
    }
}

struct ConnectionTile: View {
    let type: DatabaseType
    let color: ConnectionColor

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18

    var body: some View {
        let hasColor = color != .none
        DatabaseIconView(type: type, size: iconSize, tint: hasColor ? .white : nil)
            .frame(width: side, height: side)
            .background(
                hasColor
                    ? ConnectionColorPicker.swiftUIColor(for: color)
                    : DatabaseIconView.color(for: type).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct ConnectionRowLabels: View {
    let model: ConnectionListRowModel
    let lineLimit: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let group = model.groupLabel {
                ConnectionRowLabel(name: group.name, systemImage: "folder.fill", color: group.color)
            }
            ForEach(model.tags, id: \.self) { tag in
                ConnectionRowLabel(name: tag.name, systemImage: "tag.fill", color: tag.color)
            }
            if model.hiddenTagCount > 0 {
                Text(verbatim: "+\(model.hiddenTagCount)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(lineLimit)
    }
}

private struct ConnectionRowLabel: View {
    let name: String
    let systemImage: String
    let color: ConnectionColor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(color == .none ? Color.secondary : ConnectionColorPicker.swiftUIColor(for: color))
            Text(verbatim: name)
        }
    }
}

struct ConnectionGroupRowLabel: View {
    let group: ConnectionGroup
    let connectionCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(group.color == .none ? Color.secondary : ConnectionColorPicker.swiftUIColor(for: group.color))
                .accessibilityHidden(true)
            Text(verbatim: group.name)
                .lineLimit(1)
            Spacer()
            Text("\(connectionCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionTreeGroup: Identifiable {
    let id: UUID
    let children: [LibraryNode]
    let connectionCount: Int
}

struct ConnectionTreeLevel<ConnectionRow: View, GroupLabel: View>: View {
    let nodes: [LibraryNode]
    let canReorder: Bool
    let isExpanded: (UUID) -> Binding<Bool>
    let connectionRow: (UUID) -> ConnectionRow
    let groupLabel: (UUID, Int) -> GroupLabel
    let reorderGroups: ([UUID]) -> Void
    let reorderConnections: ([UUID]) -> Void

    var body: some View {
        let groups = nodes.compactMap { node -> ConnectionTreeGroup? in
            guard case .group(let id, let children, let count) = node else { return nil }
            return ConnectionTreeGroup(id: id, children: children, connectionCount: count)
        }
        let connectionIds = nodes.compactMap { node -> UUID? in
            guard case .connection(let id) = node else { return nil }
            return id
        }

        ForEach(groups) { group in
            DisclosureGroup(isExpanded: isExpanded(group.id)) {
                ConnectionTreeLevel(
                    nodes: group.children,
                    canReorder: canReorder,
                    isExpanded: isExpanded,
                    connectionRow: connectionRow,
                    groupLabel: groupLabel,
                    reorderGroups: reorderGroups,
                    reorderConnections: reorderConnections
                )
            } label: {
                groupLabel(group.id, group.connectionCount)
            }
        }
        .onMove(perform: canReorder ? reorder(groups.map(\.id), with: reorderGroups) : nil)

        ForEach(connectionIds, id: \.self) { id in
            connectionRow(id)
        }
        .onMove(perform: canReorder ? reorder(connectionIds, with: reorderConnections) : nil)
    }

    private func reorder(_ ids: [UUID], with commit: @escaping ([UUID]) -> Void) -> (IndexSet, Int) -> Void {
        { source, destination in
            var ordered = ids
            ordered.move(fromOffsets: source, toOffset: destination)
            commit(ordered)
        }
    }
}
