//
//  SettingsDecoding.swift
//  TablePro
//

import Foundation
import os

private let settingsDecodingLogger = Logger(subsystem: "com.TablePro", category: "SettingsDecoding")

/// Settings categories are stored and synced as one JSON blob each, so a single value that fails to
/// decode (a case from a newer build, a removed case, a hand-edited type) must cost only that field.
internal extension KeyedDecodingContainer {
    func decodeSetting<Value: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        do {
            return try decodeIfPresent(Value.self, forKey: key) ?? defaultValue()
        } catch {
            logDiscarded(key, error)
            return defaultValue()
        }
    }

    func decodeSetting<Value: Decodable>(_ key: Key) -> Value? {
        do {
            return try decodeIfPresent(Value.self, forKey: key)
        } catch {
            logDiscarded(key, error)
            return nil
        }
    }

    /// Drops the elements that fail to decode and keeps the rest.
    func decodeSettingElements<Element: Decodable>(_ key: Key) -> [Element] {
        let elements: [DiscardableSettingValue<Element>] = decodeSetting(key, default: [])
        return elements.compactMap(\.value)
    }

    /// Drops the entries whose value fails to decode and keeps the rest.
    func decodeSettingEntries<Value: Decodable>(_ key: Key) -> [String: Value] {
        let entries: [String: DiscardableSettingValue<Value>] = decodeSetting(key, default: [:])
        return entries.compactMapValues(\.value)
    }

    private func logDiscarded(_ key: Key, _ error: Error) {
        settingsDecodingLogger.warning(
            "Settings field \(key.stringValue, privacy: .public) fell back to its default: \(error.localizedDescription)"
        )
    }
}

private struct DiscardableSettingValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        do {
            value = try decoder.singleValueContainer().decode(Value.self)
        } catch {
            settingsDecodingLogger.warning(
                "Dropped a stored \(String(describing: Value.self), privacy: .public): \(error.localizedDescription)"
            )
            value = nil
        }
    }
}
