import SwiftUI
import TableProTabularIO

struct JSONValueViewer: View {
    let title: String
    let text: String

    @State private var mode: Mode = .text
    @State private var displayText: String?
    @State private var outline: JSONOutline.Result?
    @State private var expanded: Set<JSONOutlineNode.ID> = []

    var body: some View {
        Group {
            switch mode {
            case .text:
                if let displayText {
                    JSONTextView(readOnlyText: displayText)
                }
            case .tree:
                if let outline {
                    JSONTreeView(result: outline, expanded: $expanded)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Text("Text").tag(Mode.text)
                    Text("Tree").tag(Mode.tree)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
            }
        }
        .onChange(of: text, initial: true) { _, newText in
            render(newText)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .tree, outline == nil {
                buildOutline(text)
            }
        }
    }

    private func render(_ text: String) {
        displayText = JSONPrettyPrinter.format(text) ?? text
        if mode == .tree {
            buildOutline(text)
        } else {
            outline = nil
        }
    }

    private func buildOutline(_ text: String) {
        let result = JSONOutline.build(text)
        if case .tree(let root, _) = result, outline == nil, expanded.isEmpty {
            expanded = JSONTreeView.defaultExpansion(of: root)
        }
        outline = result
    }

    private func copy() {
        ClipboardExporter.copyToClipboard(text)
    }

    private enum Mode: Hashable {
        case text
        case tree
    }
}

extension JSONValueViewer {
    struct Route: Hashable {
        let title: String
        let text: String
    }

    init(route: Route) {
        self.init(title: route.title, text: route.text)
    }
}
