//
//  ObjectSourceView.swift
//  TablePro
//
//  Read-only source of one database object, with the toolbar that goes above it.
//

import AppKit
import SwiftUI

/// The one place the app draws an object's source. The Structure tab's trigger inspector and the
/// object viewer tab both use it, so the font stepper, Copy, Export and Open in Editor behave the
/// same wherever a definition is shown.
struct ObjectSourceView: View {
    let source: String
    let databaseType: DatabaseType
    let exportFileName: String
    var attributes: [ObjectAttribute] = []
    var onOpenInEditor: (() -> Void)?

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) private var fontSize: Double = 13
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !attributes.isEmpty {
                ObjectAttributeStrip(attributes: attributes)
                Divider()
            }
            DDLTextView(ddl: source, fontSize: $fontSize, databaseType: databaseType)
        }
        .alert(
            String(localized: "Export Failed"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var hasSource: Bool { !source.isEmpty }

    private var toolbar: some View {
        HStack(spacing: 12) {
            fontStepper
            Spacer()
            if let onOpenInEditor {
                Button(action: onOpenInEditor) {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .disabled(!hasSource)
            }
            Button {
                ClipboardService.shared.writeText(source)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(!hasSource)
            Button {
                Task { await export() }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!hasSource)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var fontStepper: some View {
        HStack(spacing: 4) {
            Button {
                fontSize = max(10, fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Decrease font size"))
            Text("\(Int(fontSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Button {
                fontSize = min(24, fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Increase font size"))
        }
        .buttonStyle(.borderless)
    }

    @MainActor
    private func export() async {
        guard let url = await SQLFileService.showSavePanel(suggestedName: exportFileName) else { return }
        do {
            try await SQLFileService.writeFile(content: source, to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// What the driver said about the object, in the order it said it. The app renders the pairs and
/// never interprets them, so an engine can describe volatility, security or a trigger's Java class
/// without the app learning that vocabulary.
struct ObjectAttributeStrip: View {
    let attributes: [ObjectAttribute]

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 320), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(attributes) { attribute in
                HStack(spacing: 6) {
                    Text(attribute.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(attribute.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(attribute.value)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
