import SwiftUI

enum AIProviderAddChoice: Hashable, Identifiable {
    case type(AIProviderType)
    case preset(String)
    case custom

    var id: String {
        switch self {
        case .type(let type): "type.\(type.rawValue)"
        case .preset(let id): "preset.\(id)"
        case .custom: "custom"
        }
    }

    var preset: AIProviderPreset? {
        guard case .preset(let id) = self else { return nil }
        return AIProviderPreset.preset(withID: id)
    }

    var title: String {
        switch self {
        case .type(let type): type.displayName
        case .preset: preset?.displayName ?? AIProviderType.custom.displayName
        case .custom: String(localized: "Custom Provider")
        }
    }

    var icon: BrandIcon {
        switch self {
        case .type(let type): type.icon
        case .preset: preset?.icon ?? AIProviderType.custom.icon
        case .custom: AIProviderType.custom.icon
        }
    }

    func makeProvider(descriptor: (AIProviderType) -> AIProviderDescriptor?) -> AIProviderConfig {
        switch self {
        case .type(let type):
            return AIProviderConfig(
                type: type,
                endpoint: type.defaultEndpoint,
                telemetryEnabled: descriptor(type)?.defaultTelemetryEnabled ?? false
            )
        case .preset:
            guard let preset else { return AIProviderConfig(type: .custom) }
            return AIProviderConfig(preset: preset)
        case .custom:
            return AIProviderConfig(
                type: .custom,
                telemetryEnabled: descriptor(.custom)?.defaultTelemetryEnabled ?? false
            )
        }
    }
}

enum AIProviderAddMenu {
    struct Groups: Equatable {
        var signIn: [AIProviderAddChoice] = []
        var apiKey: [AIProviderAddChoice] = []
        var onThisMac: [AIProviderAddChoice] = []
        var includesCustom = false
    }

    static func groups(registry: AIProviderRegistry = .shared) -> Groups {
        groups { registry.descriptor(for: $0.rawValue) != nil }
    }

    static func groups(
        isRegistered: (AIProviderType) -> Bool,
        presets: [AIProviderPreset] = AIProviderPreset.all
    ) -> Groups {
        var groups = Groups()
        for type in AIProviderType.allCases where type != .custom && isRegistered(type) {
            if type.authStyle == .oauth || type == .claudeAgent {
                groups.signIn.append(.type(type))
            } else if type.authStyle.usesAPIKey {
                groups.apiKey.append(.type(type))
            } else {
                groups.onThisMac.append(.type(type))
            }
        }
        if isRegistered(.custom) {
            groups.apiKey += presets.map { .preset($0.id) }
            groups.includesCustom = true
        }
        return groups
    }
}

struct AIProviderAddMenuButton: View {
    let onChoose: (AIProviderAddChoice) -> Void

    var body: some View {
        let groups = AIProviderAddMenu.groups()
        Menu {
            if !groups.signIn.isEmpty {
                Section(String(localized: "Sign In With an Account")) { items(groups.signIn) }
            }
            if !groups.apiKey.isEmpty {
                Section(String(localized: "API Key")) { items(groups.apiKey) }
            }
            if !groups.onThisMac.isEmpty {
                Section(String(localized: "On This Mac")) { items(groups.onThisMac) }
            }
            if groups.includesCustom {
                Divider()
                item(.custom)
            }
        } label: {
            Text("Add Provider")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .accessibilityIdentifier("settings-ai-add-provider")
    }

    private func items(_ choices: [AIProviderAddChoice]) -> some View {
        ForEach(choices) { choice in
            item(choice)
        }
    }

    private func item(_ choice: AIProviderAddChoice) -> some View {
        Button {
            onChoose(choice)
        } label: {
            Label {
                Text(verbatim: "\(choice.title)…")
            } icon: {
                choice.icon.menuImage()
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
