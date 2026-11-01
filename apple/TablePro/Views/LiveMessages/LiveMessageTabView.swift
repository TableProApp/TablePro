//
//  LiveMessageTabView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

// A live tab exists only with a live controller, so a tab that has none says so rather than drawing an empty table.
internal struct LiveMessageTabContent: View {
    let tabId: UUID

    var body: some View {
        if let controller = LiveMessageSessions.shared.controller(forTab: tabId) {
            LiveMessageTabView(controller: controller)
        } else {
            UnavailableStateView(String(localized: "Live Messages Ended"), systemImage: "dot.radiowaves.left.and.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

internal struct LiveMessageTabView: View {
    @ObservedObject var controller: LiveMessageController
    @State private var selection = Set<LiveMessageEntry.ID>()
    @State private var publishChannel = ""
    @State private var publishPayload = ""
    @State private var isPublishing = false
    @State private var publishError: String?

    // Newest first, so an arriving message is in sight without scrolling.
    private var rows: [LiveMessageEntry] {
        controller.shown.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
                .paneBarBackground()
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            publishBar
                .paneBarBackground()
        }
        .onAppear {
            if publishChannel.isEmpty {
                publishChannel = controller.request.channels.first ?? ""
            }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 8)
            if controller.isPaused, controller.unseenCount > 0 {
                Text(String(format: String(localized: "%d new"), controller.unseenCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(String(format: String(localized: "%d messages"), controller.shown.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            NativeSearchField(
                text: $controller.filter,
                placeholder: String(localized: "Filter"),
                controlSize: .small,
                accessibilityIdentifier: "live-messages-filter"
            )
            .frame(width: 180)
            Button {
                controller.isPaused ? controller.resume() : controller.pause()
            } label: {
                Label(
                    controller.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                    systemImage: controller.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .help(controller.isPaused
                ? String(localized: "Show the messages that arrived while paused")
                : String(localized: "Freeze the list; messages keep arriving underneath"))
            Button(String(localized: "Clear")) {
                selection.removeAll()
                controller.clear()
            }
            Button(String(localized: "Copy")) { copy() }
                .disabled(controller.shown.isEmpty)
            Button(String(localized: "Export…")) { export() }
                .disabled(controller.shown.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .connecting:
            Label(String(localized: "Connecting…"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .live:
            Label(LiveMessageController.title(for: controller.request), systemImage: "dot.radiowaves.left.and.right")
                .lineLimit(1)
                .truncationMode(.tail)
        case .reconnecting(let reason):
            Label(String(localized: "Reconnecting…"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .help(reason)
        case .ended(let error):
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(error)
            } else {
                Label(String(localized: "Stopped"), systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        switch controller.kind {
        case .pubSub:
            Table(rows, selection: $selection) {
                timeColumn
                textColumn(.channel)
                textColumn(.pattern)
                textColumn(.payload)
            }
            .onCopyCommand { copyProviders() }
        case .topics:
            Table(rows, selection: $selection) {
                timeColumn
                textColumn(.channel)
                textColumn(.partition)
                textColumn(.offset)
                textColumn(.key)
                textColumn(.payload)
            }
            .onCopyCommand { copyProviders() }
        case .notifications:
            channelTable
        @unknown default:
            channelTable
        }
    }

    private var channelTable: some View {
        Table(rows, selection: $selection) {
            timeColumn
            textColumn(.channel)
            textColumn(.payload)
        }
        .onCopyCommand { copyProviders() }
    }

    private var timeColumn: TableColumn<LiveMessageEntry, Never, Text, Text> {
        TableColumn(LiveMessageExport.Column.time.title) { entry in
            Text(entry.message.map { $0.timestamp.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))) } ?? "")
                .monospacedDigit()
        }
    }

    private func textColumn(_ column: LiveMessageExport.Column) -> TableColumn<LiveMessageEntry, Never, Text, Text> {
        TableColumn(column.title) { entry in
            let text = Text(LiveMessageExport.value(of: column, in: entry))
            if entry.message == nil {
                return text.foregroundColor(.secondary).italic()
            }
            return text
        }
    }

    // MARK: - Publish

    private var publishBar: some View {
        HStack(spacing: 8) {
            Text(LiveMessageKindText.publishTitle(controller.kind))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(LiveMessageKindText.channelsLabel(controller.kind), text: $publishChannel)
                .frame(width: 160)
                .accessibilityIdentifier("live-messages-publish-channel")
            TextField(String(localized: "Payload"), text: $publishPayload)
                .onSubmit { send() }
                .accessibilityIdentifier("live-messages-publish-payload")
            Button(String(localized: "Send")) { send() }
                .disabled(!controller.canPublish || isPublishing
                    || publishChannel.trimmingCharacters(in: .whitespaces).isEmpty)
            if let publishError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(publishError)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func send() {
        let channel = publishChannel.trimmingCharacters(in: .whitespaces)
        guard controller.canPublish, !isPublishing, !channel.isEmpty else { return }
        let payload = publishPayload
        isPublishing = true
        publishError = nil
        Task {
            do {
                try await controller.publish(payload, to: channel)
                publishPayload = ""
            } catch {
                publishError = error.localizedDescription
            }
            isPublishing = false
        }
    }

    // MARK: - Copy and export

    private var selectedOrAll: [LiveMessageEntry] {
        let chosen = controller.shown.filter { selection.contains($0.id) }
        return chosen.isEmpty ? controller.shown : chosen
    }

    private func copy() {
        ClipboardService.shared.writeText(LiveMessageExport.tsv(selectedOrAll, kind: controller.kind))
    }

    private func copyProviders() -> [NSItemProvider] {
        [NSItemProvider(object: LiveMessageExport.tsv(selectedOrAll, kind: controller.kind) as NSString)]
    }

    private func export() {
        let text = LiveMessageExport.csv(controller.shown, kind: controller.kind)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "live-messages.csv"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Can't Export Messages"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }
}
