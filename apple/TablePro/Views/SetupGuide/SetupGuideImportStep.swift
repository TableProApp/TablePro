import AppKit
import SwiftUI

internal struct SetupGuideImportStep: View {
    @ObservedObject var model: SetupGuideModel

    private var cards: [ForeignSourceRow] {
        model.sources.filter { $0.availability != .notFound }
    }

    private var notFound: [String] {
        model.sources.filter { $0.availability == .notFound }.map(\.importer.displayName)
    }

    private var foundNoApp: Bool {
        !model.sources.contains { !$0.picksFile && $0.availability != .notFound }
    }

    var body: some View {
        if case .scanning = model.importPhase {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: String(localized: "Looking for other database apps…"))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if foundNoApp {
                    emptyNote
                        .padding(.bottom, 6)
                }
                ForEach(cards) { row in
                    SetupGuideSourceCard(model: model, row: row)
                }
                if !notFound.isEmpty {
                    Text(verbatim: String(
                        format: String(localized: "Not found on this Mac: %@"),
                        ListFormatter.localizedString(byJoining: notFound)
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("setup-guide-not-found")
                }
            }
        }
    }

    private var emptyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: String(localized: "No other database apps found on this Mac."))
            } icon: {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            Text(verbatim: String(localized: "Continue to add a connection or open the sample database."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupGuideSourceCard: View {
    @ObservedObject var model: SetupGuideModel
    let row: ForeignSourceRow

    @State private var isHovered = false
    @State private var isPressed = false

    private var isAvailable: Bool {
        row.availability == .available
    }

    private var isTicked: Bool {
        model.ticked.contains(row.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { isTicked }, set: { model.setTicked($0, for: row) })) {
                SetupGuideSourceLabel(model: model, row: row)
            }
            .toggleStyle(SetupGuideCardToggleStyle(showsIndicator: isAvailable, isPressed: $isPressed))
            .disabled(!isAvailable)
            .accessibilityIdentifier("setup-guide-source-\(row.id)")

            if isTicked {
                options
                    .padding(.leading, 16 + 48)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .modifier(SetupGuideCardBackground(
            isSelected: isTicked,
            isHovered: isHovered && isAvailable && !model.isRunningImport,
            isPressed: isPressed
        ))
        .onHover { isHovered = $0 }
        .disabled(model.isRunningImport)
    }

    private var options: some View {
        let request = model.request(for: row)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { request.includePasswords }, set: { model.setIncludePasswords($0, for: row) })) {
                Text(verbatim: row.importer.readsPasswordsFromKeychain
                    ? String(localized: "Include passwords (macOS asks for each one)")
                    : String(localized: "Include passwords"))
            }
            .accessibilityIdentifier("setup-guide-passwords-\(row.id)")
            if model.offersSavedQueries(row) {
                Toggle(isOn: Binding(get: { request.includeSavedQueries }, set: { model.setIncludeSavedQueries($0, for: row) })) {
                    Text(verbatim: String(localized: "Include saved queries"))
                }
                .accessibilityIdentifier("setup-guide-queries-\(row.id)")
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

private struct SetupGuideSourceLabel: View {
    @ObservedObject var model: SetupGuideModel
    let row: ForeignSourceRow

    @Environment(\.isEnabled) private var isEnabled

    private var isCurrent: Bool {
        model.currentSourceId == row.id
    }

    // A disabled card dims, but the line saying why it cannot be ticked, or what the queue is doing, stays legible.
    private var dimming: Double {
        isEnabled || isCurrent ? 1 : 0.5
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon
                .frame(width: 36, height: 36)
                .opacity(dimming)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.importer.displayName)
                    .font(.headline)
                    .opacity(dimming)
                status
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 36, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        if isCurrent, case .pickingFile = model.importPhase {
            Text(verbatim: String(format: String(localized: "Choose a %@ export file to import"), row.importer.displayName))
        } else if isCurrent, case .reading(let appName) = model.importPhase {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: String(format: String(localized: "Reading connections from %@…"), appName))
                }
                Text(verbatim: String(localized: "If macOS asks for your login password, click Always Allow on each prompt."))
                    .font(.footnote)
            }
        } else if let result = model.results[row.id] {
            outcome(result)
                .opacity(dimming)
        } else if row.picksFile {
            Text(verbatim: String(localized: "Imports from an export file you choose"))
                .opacity(dimming)
        } else {
            availability
        }
    }

    @ViewBuilder
    private var availability: some View {
        switch row.availability {
        case .available:
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ImportFromAppSourcePicker.connectionsFound(row.inventory.connections))
                    .contentTransition(.numericText())
                if let queries = ImportFromAppSourcePicker.savedQueriesFound(row.inventory.savedQueries) {
                    Text(verbatim: queries)
                        .contentTransition(.numericText())
                }
            }
            .opacity(dimming)
        case .notFound:
            EmptyView()
        case .unreadable(let reason):
            Label {
                Text(verbatim: reason)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
            .help(reason)
        }
    }

    private func outcome(_ result: SetupGuideImportResult) -> some View {
        Label {
            Text(verbatim: result.message)
                .lineLimit(3)
        } icon: {
            Image(systemName: Self.symbol(for: result))
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let appURL = row.importer.installedAppURL() {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: row.importer.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    private static func symbol(for result: SetupGuideImportResult) -> String {
        switch result {
        case .imported: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
