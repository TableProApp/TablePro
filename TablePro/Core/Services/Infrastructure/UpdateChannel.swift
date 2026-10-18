import Foundation

internal enum UpdateChannel: String, Sendable {
    case stable
    case beta
}

internal extension UpdateChannel {
    // Sparkle always adds its default channel, which carries every stable item.
    var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: [Self.beta.rawValue]
        }
    }

    func accepts(_ releaseChannel: String) -> Bool {
        switch self {
        case .stable: releaseChannel == Self.stable.rawValue
        case .beta: Self(rawValue: releaseChannel) != nil
        }
    }

    static func selected(in defaults: UserDefaults) -> UpdateChannel {
        defaults.bool(forKey: PreferenceKeys.receivesBetaUpdates.name) ? .beta : .stable
    }

    static func select(_ channel: UpdateChannel, in defaults: UserDefaults) {
        defaults.set(channel == .beta, forKey: PreferenceKeys.receivesBetaUpdates.name)
    }

    static func clearSelection(in defaults: UserDefaults) {
        defaults.removeObject(forKey: PreferenceKeys.receivesBetaUpdates.name)
    }
}
