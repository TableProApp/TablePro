//
//  SettingsValidation.swift
//  TablePro
//
//  Validation rules and utilities for app settings.
//  Provides centralized validation logic with Swift extensions.
//

import Foundation

// MARK: - Validation Error

/// Validation error for settings
enum SettingsValidationError: LocalizedError {
    case stringTooLong(field: String, maxLength: Int)
    case stringEmpty(field: String)
    case intOutOfRange(field: String, min: Int, max: Int)
    case intNegative(field: String)

    var errorDescription: String? {
        switch self {
        case .stringTooLong(let field, let maxLength):
            return String(localized: "\(field) must be \(maxLength) characters or less")
        case .stringEmpty(let field):
            return String(localized: "\(field) cannot be empty")
        case .intOutOfRange(let field, let min, let max):
            return String(localized: "\(field) must be between \(min.formatted()) and \(max.formatted())")
        case .intNegative(let field):
            return String(localized: "\(field) cannot be negative")
        }
    }
}

// MARK: - String Validation

extension String {
    /// Sanitize string for settings: strip newlines/tabs, trim whitespace
    var sanitized: String {
        self.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Validate and clamp string length
    func validated(maxLength: Int, allowEmpty: Bool = false) -> Result<String, SettingsValidationError> {
        let cleaned = self.sanitized

        if !allowEmpty && cleaned.isEmpty {
            return .failure(.stringEmpty(field: "String"))
        }

        if (cleaned as NSString).length > maxLength {
            return .failure(.stringTooLong(field: "String", maxLength: maxLength))
        }

        return .success(cleaned)
    }
}

// MARK: - Int Validation

extension Int {
    /// Clamp integer to range
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// Validate integer is in range
    func validated(in range: ClosedRange<Int>) -> Result<Int, SettingsValidationError> {
        if self < range.lowerBound || self > range.upperBound {
            return .failure(.intOutOfRange(
                field: "Value",
                min: range.lowerBound,
                max: range.upperBound
            ))
        }
        return .success(self)
    }

    /// Validate integer is non-negative
    func validatedNonNegative() -> Result<Int, SettingsValidationError> {
        if self < 0 {
            return .failure(.intNegative(field: "Value"))
        }
        return .success(self)
    }
}

// MARK: - Validation Constants

enum SettingsValidationRules {
    // String validation
    static let nullDisplayMaxLength = 20

    // Int validation
    static let defaultPageSizeRange = 10...100_000
    static let minNonNegative = 0
}
