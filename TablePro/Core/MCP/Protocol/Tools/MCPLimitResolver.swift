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

    static func resolveMaxRows(_ args: JsonValue, key: String = "max_rows", settings: MCPSettings) throws -> Int {
        guard let requested = try MCPArgumentDecoder.optionalInt(
            args,
            key: key,
            range: settings.requestableRowLimitRange
        ) else {
            return settings.effectiveDefaultRowLimit
        }
        return requested
    }

    static func resolveTimeoutSeconds(
        _ args: JsonValue,
        key: String = "timeout_seconds",
        settings: MCPSettings
    ) throws -> Int {
        guard let requested = try MCPArgumentDecoder.optionalInt(
            args,
            key: key,
            range: SettingsValidationRules.mcpQueryTimeoutRange
        ) else {
            return settings.validatedQueryTimeoutSeconds
        }
        return requested
    }
}
