import Foundation

enum MCPLimitResolver {
    static func resolveMaxRows(requested: Int?, settings: MCPSettings) -> Int {
        guard let requested else { return settings.effectiveDefaultRowLimit }
        return requested.clamped(to: settings.requestableRowLimitRange)
    }

    static func resolveTimeoutSeconds(requested: Int?, settings: MCPSettings) -> Int {
        guard let requested else { return settings.validatedQueryTimeoutSeconds }
        return requested.clamped(to: SettingsValidationRules.mcpQueryTimeoutRange)
    }
}
