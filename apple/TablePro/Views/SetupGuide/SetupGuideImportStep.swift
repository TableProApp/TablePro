//
//  SetupGuideImportStep.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct SetupGuideImportStep: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        switch model.importPhase {
        case .scanning:
            progress(String(localized: "Looking for other database apps…"), caption: nil, cancel: nil)
        case .choosing:
            sourceList
        case .pickingFile(let row):
            filePrompt(for: row)
        case .notice(let notice):
            VStack {
                Spacer()
                KeychainNoticeView(
                    notice: notice,
                    onContinue: { model.confirmKeychainNotice() },
                    onCancel: { model.skipCurrentSource() }
                )
                .frame(maxWidth: 480)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .reading(let appName):
            progress(
                String(format: String(localized: "Reading connections from %@…"), appName),
                caption: String(localized: "If macOS asks for your login password, click Always Allow on each prompt."),
                cancel: { model.skipCurrentSource() }
            )
        case .review(let read, let id):
            ImportReviewStep(
                title: read.title,
                banner: read.banner,
                preview: read.preview,
                onBack: nil,
                onCancel: { model.skipCurrentSource() },
                onFinished: { model.reviewFinished($0) }
            )
            .id(id)
        }
    }

    @ViewBuilder
    private var sourceList: some View {
        if model.sources.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No other database apps found on this Mac.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(model.sources) { row in
                    SetupGuideSourceRow(model: model, row: row)
                }
            }
            .listStyle(.inset)
        }
    }

    private func progress(_ title: String, caption: String?, cancel: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let caption {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            if let cancel {
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel"), action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func filePrompt(for row: ForeignSourceRow) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: row.importer.symbolName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(format: String(localized: "Choose a %@ export file to import"), row.importer.displayName))
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Skip This App")) { model.skipCurrentSource() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Choose File…")) { chooseFile(for: row) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseFile(for row: ForeignSourceRow) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = row.importer.importFileTypes {
            panel.allowedContentTypes = types
        }
        panel.message = String(format: String(localized: "Choose a %@ export file to import"), row.importer.displayName)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.fileChosen(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

private struct SetupGuideSourceRow: View {
    @ObservedObject var model: SetupGuideModel
    let row: ForeignSourceRow

    private var isAvailable: Bool {
        row.availability == .available
    }

    private var isTicked: Bool {
        model.ticked.contains(row.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isTicked }, set: { model.setTicked($0, for: row) })) {
                HStack(spacing: 10) {
                    appIcon
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.importer.displayName)
                        status
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!isAvailable)
            .accessibilityIdentifier("setup-guide-source-\(row.id)")

            if isTicked {
                options
                    .padding(.leading, 58)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        if let result = model.results[row.id] {
            Label {
                Text(verbatim: result.message)
                    .lineLimit(3)
            } icon: {
                Image(systemName: Self.symbol(for: result))
                    .accessibilityHidden(true)
            }
        } else if row.picksFile {
            Text("Imports from an export file you choose")
        } else {
            switch row.availability {
            case .available where model.counting.contains(row.id):
                Text(verbatim: String(localized: "Counting connections…"))
            case .available where !row.isCounted:
                Text(verbatim: String(localized: "Select to count its connections. macOS may ask for access first."))
            case .available:
                Text(verbatim: ImportFromAppSourcePicker.connectionsFound(row.inventory.connections))
                if let queries = ImportFromAppSourcePicker.savedQueriesFound(row.inventory.savedQueries) {
                    Text(verbatim: queries)
                }
            case .notFound:
                Text("Not installed")
            case .unreadable(let reason):
                Label {
                    Text(verbatim: reason)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                .help(reason)
            }
        }
    }

    private var options: some View {
        let request = model.request(for: row)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { request.includePasswords }, set: { model.setIncludePasswords($0, for: row) })) {
                Text(row.importer.readsPasswordsFromKeychain
                    ? String(localized: "Include passwords (macOS asks for each one)")
                    : String(localized: "Include passwords"))
            }
            .accessibilityIdentifier("setup-guide-passwords-\(row.id)")
            if model.offersSavedQueries(row) {
                Toggle(isOn: Binding(get: { request.includeSavedQueries }, set: { model.setIncludeSavedQueries($0, for: row) })) {
                    Text("Include saved queries")
                }
                .accessibilityIdentifier("setup-guide-queries-\(row.id)")
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let appURL = row.importer.installedAppURL() {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: row.importer.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private static func symbol(for result: SetupGuideImportResult) -> String {
        switch result {
        case .imported: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
