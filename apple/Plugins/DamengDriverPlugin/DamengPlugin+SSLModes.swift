import TableProPluginKit

// The bridge opens plain TCP only, so Preferred falls back to it and nothing stronger can be kept.
extension DamengPlugin {
    static var supportedSSLModes: [SSLMode] { [.disabled, .preferred] }
}
