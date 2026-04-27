//
//  BooleanValueMapper.swift
//  TablePro
//

import AppKit

enum BooleanValueMapper {
    static func state(for rawValue: String?) -> NSControl.StateValue {
        guard let rawValue else { return .mixed }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .mixed }

        switch trimmed.lowercased() {
        case "1", "true", "t", "yes", "y", "on":
            return .on
        case "0", "false", "f", "no", "n", "off":
            return .off
        default:
            return .mixed
        }
    }

    static func rawValue(for state: NSControl.StateValue, usesTrueFalse: Bool) -> String? {
        switch state {
        case .on:
            return usesTrueFalse ? "true" : "1"
        case .off:
            return usesTrueFalse ? "false" : "0"
        default:
            return nil
        }
    }
}
