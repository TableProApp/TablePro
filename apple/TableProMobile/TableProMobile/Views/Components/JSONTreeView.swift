import SwiftUI
import TableProTabularIO

struct JSONTreeView: View {
    let result: JSONOutline.Result
    @Binding var expanded: Set<JSONOutlineNode.ID>

    var body: some View {
        switch result {
        case .tree(let root, let omitted):
            List {
                ForEach(Self.topLevelNodes(of: root)) { node in
                    JSONTreeRow(node: node, expanded: $expanded)
                }
                if omitted > 0 {
                    Text(String(format: String(localized: "%lld more not shown"), Int64(omitted)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        case .tooLarge:
            ContentUnavailableView(
                "JSON Too Large",
                systemImage: "doc.text",
                description: Text("This JSON document is too large for tree view. Use text mode instead.")
            )
        case .invalid:
            ContentUnavailableView(
                "Invalid JSON",
                systemImage: "exclamationmark.triangle",
                description: Text("The text could not be parsed as JSON. Use text mode to read it.")
            )
        }
    }

    static func topLevelNodes(of root: JSONOutlineNode) -> [JSONOutlineNode] {
        root.children ?? [root]
    }

    static func defaultExpansion(of root: JSONOutlineNode) -> Set<JSONOutlineNode.ID> {
        Set(topLevelNodes(of: root).filter { $0.children != nil }.map(\.id))
    }
}

private struct JSONTreeRow: View {
    let node: JSONOutlineNode
    @Binding var expanded: Set<JSONOutlineNode.ID>

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { child in
                    JSONTreeRow(node: child, expanded: $expanded)
                }
            } label: {
                JSONTreeLabel(node: node)
            }
        } else {
            JSONTreeLabel(node: node)
        }
    }

    private var isExpanded: Binding<Bool> {
        let id = node.id
        return Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(id)
                } else {
                    expanded.remove(id)
                }
            }
        )
    }
}

private struct JSONTreeLabel: View {
    let node: JSONOutlineNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let key = keyText {
                Text(verbatim: key)
                    .foregroundStyle(isIndex ? HierarchicalShapeStyle.secondary : .primary)
            }
            Text(verbatim: valueText)
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
        .font(.system(.body, design: .monospaced))
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Copy Value", systemImage: "doc.on.doc", action: copyValue)
            if memberName != nil {
                Button("Copy Key", systemImage: "textformat", action: copyKey)
            }
            Button("Copy Key Path", systemImage: "arrow.turn.down.right", action: copyKeyPath)
        }
    }

    private var memberName: String? {
        guard case .member(let name) = node.key else { return nil }
        return name
    }

    private var isIndex: Bool {
        guard case .index = node.key else { return false }
        return true
    }

    private var keyText: String? {
        switch node.key {
        case .root: return nil
        case .member(let name): return name
        case .index(let index): return "[\(index)]"
        }
    }

    private var valueText: String {
        switch node.value {
        case .object(let count):
            let summary = count == 1
                ? String(localized: "1 key")
                : String(format: String(localized: "%lld keys"), Int64(count))
            return "{\(summary)}"
        case .array(let count):
            let summary = count == 1
                ? String(localized: "1 item")
                : String(format: String(localized: "%lld items"), Int64(count))
            return "[\(summary)]"
        case .string(let string):
            return "\"\(string)\""
        case .number(let lexeme):
            return lexeme
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private func copyValue() {
        ClipboardExporter.copyToClipboard(node.copyText)
    }

    private func copyKey() {
        guard let memberName else { return }
        ClipboardExporter.copyToClipboard(memberName)
    }

    private func copyKeyPath() {
        ClipboardExporter.copyToClipboard(node.keyPath)
    }
}
