//
//  LiveMessageStartSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct LiveMessageStartSheet: View {
    let kind: PluginLiveMessageKind
    let onFinish: @MainActor (PluginLiveSubscriptionRequest?) -> Void

    @State private var channels: String
    @State private var patterns = ""

    init(
        kind: PluginLiveMessageKind,
        suggestedChannel: String,
        onFinish: @escaping @MainActor (PluginLiveSubscriptionRequest?) -> Void
    ) {
        self.kind = kind
        self.onFinish = onFinish
        _channels = State(initialValue: suggestedChannel)
    }

    // Commas or new lines separate names; a name itself may hold spaces.
    nonisolated static func names(in text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var request: PluginLiveSubscriptionRequest {
        PluginLiveSubscriptionRequest(
            channels: Self.names(in: channels),
            patterns: kind == .pubSub ? Self.names(in: patterns) : []
        )
    }

    private var canStart: Bool {
        !request.channels.isEmpty || !request.patterns.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LiveMessageKindText.sheetTitle(kind))
                .font(.headline)
            Form {
                TextField(LiveMessageKindText.channelsLabel(kind), text: $channels)
                    .accessibilityIdentifier("live-messages-channels")
                if kind == .pubSub {
                    TextField(String(localized: "Patterns"), text: $patterns)
                        .accessibilityIdentifier("live-messages-patterns")
                }
            }
            Text(LiveMessageKindText.sheetNote(kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(LiveMessageKindText.startTitle(kind)) { onFinish(request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

internal enum LiveMessageKindText {
    static func sheetTitle(_ kind: PluginLiveMessageKind) -> String {
        switch kind {
        case .pubSub: String(localized: "Subscribe to Channels")
        case .topics: String(localized: "Follow Topics")
        case .notifications: String(localized: "Listen for Notifications")
        @unknown default: String(localized: "Listen for Notifications")
        }
    }

    static func channelsLabel(_ kind: PluginLiveMessageKind) -> String {
        kind == .topics ? String(localized: "Topics") : String(localized: "Channels")
    }

    static func startTitle(_ kind: PluginLiveMessageKind) -> String {
        switch kind {
        case .pubSub: String(localized: "Subscribe")
        case .topics: String(localized: "Follow")
        case .notifications: String(localized: "Listen")
        @unknown default: String(localized: "Listen")
        }
    }

    static func sheetNote(_ kind: PluginLiveMessageKind) -> String {
        switch kind {
        case .pubSub:
            String(localized: "Separate names with commas. Patterns use glob syntax, such as news.*. A separate connection subscribes and closes with the tab.")
        case .topics:
            String(localized: "Separate names with commas. Reading starts at the end of each partition, without a consumer group, so no committed offset moves.")
        case .notifications:
            String(localized: "Separate names with commas. A separate session runs LISTEN and closes with the tab.")
        @unknown default:
            String(localized: "Separate names with commas.")
        }
    }

    static func publishTitle(_ kind: PluginLiveMessageKind) -> String {
        switch kind {
        case .pubSub: "PUBLISH"
        case .topics: String(localized: "Produce")
        case .notifications: "NOTIFY"
        @unknown default: String(localized: "Send")
        }
    }
}
