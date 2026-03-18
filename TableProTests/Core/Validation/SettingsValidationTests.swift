//
//  SettingsValidationTests.swift
//  TableProTests
//
//  Tests for settings validation utilities and rules.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Settings Validation")
struct SettingsValidationTests {
    // MARK: - String Sanitization Tests

    @Test("String sanitization removes newlines")
    func sanitizationRemovesNewlines() {
        let input = "Hello\nWorld"
        let result = input.sanitized
        #expect(result == "HelloWorld")
    }

    @Test("String sanitization removes carriage returns")
    func sanitizationRemovesCarriageReturns() {
        let input = "Hello\rWorld"
        let result = input.sanitized
        #expect(result == "HelloWorld")
    }

    @Test("String sanitization converts tabs to spaces")
    func sanitizationConvertsTabsToSpaces() {
        let input = "Hello\tWorld"
        let result = input.sanitized
        #expect(result == "Hello World")
    }

    @Test("String sanitization trims whitespace")
    func sanitizationTrimsWhitespace() {
        let input = "  Hello World  "
        let result = input.sanitized
        #expect(result == "Hello World")
    }

    @Test("String sanitization handles multiple tabs")
    func sanitizationHandlesMultipleTabs() {
        let input = "Hello\t\tWorld"
        let result = input.sanitized
        #expect(result == "Hello  World")
    }

    @Test("String sanitization handles complex input")
    func sanitizationHandlesComplexInput() {
        let input = "  \n\tHello\r\n\tWorld\t  "
        let result = input.sanitized
        #expect(result == "Hello World")
    }

    // MARK: - String Validation Tests

    @Test("String validation succeeds for valid input")
    func stringValidationSucceeds() {
        let input = "ValidString"
        let result = input.validated(maxLength: 20)
        guard case .success(let value) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(value == "ValidString")
    }

    @Test("String validation rejects empty string by default")
    func stringValidationRejectsEmpty() {
        let input = ""
        let result = input.validated(maxLength: 20)
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .stringEmpty = error {
            // Expected error type
        } else {
            Issue.record("Expected stringEmpty error")
        }
    }

    @Test("String validation allows empty when flagged")
    func stringValidationAllowsEmptyWhenFlagged() {
        let input = ""
        let result = input.validated(maxLength: 20, allowEmpty: true)
        guard case .success(let value) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(value == "")
    }

    @Test("String validation rejects too long string")
    func stringValidationRejectsTooLong() {
        let input = "ThisStringIsTooLongForTheLimit"
        let result = input.validated(maxLength: 10)
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .stringTooLong(_, let maxLength) = error {
            #expect(maxLength == 10)
        } else {
            Issue.record("Expected stringTooLong error")
        }
    }

    @Test("String validation accepts string at exact max length")
    func stringValidationAcceptsExactMaxLength() {
        let input = "TenCharStr"
        let result = input.validated(maxLength: 10)
        guard case .success(let value) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(value == "TenCharStr")
    }

    @Test("String validation sanitizes before validating")
    func stringValidationSanitizesFirst() {
        let input = "  Valid\nString  "
        let result = input.validated(maxLength: 20)
        guard case .success(let value) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(value == "ValidString")
    }

    // MARK: - Int Clamping Tests

    @Test("Int clamping clamps below range")
    func intClampingClampsBelowRange() {
        let value = 5
        let result = value.clamped(to: 10...20)
        #expect(result == 10)
    }

    @Test("Int clamping clamps above range")
    func intClampingClampsAboveRange() {
        let value = 25
        let result = value.clamped(to: 10...20)
        #expect(result == 20)
    }

    @Test("Int clamping preserves value within range")
    func intClampingPreservesValueWithinRange() {
        let value = 15
        let result = value.clamped(to: 10...20)
        #expect(result == 15)
    }

    @Test("Int clamping preserves value at lower bound")
    func intClampingPreservesValueAtLowerBound() {
        let value = 10
        let result = value.clamped(to: 10...20)
        #expect(result == 10)
    }

    @Test("Int clamping preserves value at upper bound")
    func intClampingPreservesValueAtUpperBound() {
        let value = 20
        let result = value.clamped(to: 10...20)
        #expect(result == 20)
    }

    // MARK: - Int Validation Tests

    @Test("Int validation succeeds for value in range")
    func intValidationSucceeds() {
        let value = 15
        let result = value.validated(in: 10...20)
        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated == 15)
    }

    @Test("Int validation fails for value below range")
    func intValidationFailsBelowRange() {
        let value = 5
        let result = value.validated(in: 10...20)
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .intOutOfRange(_, let min, let max) = error {
            #expect(min == 10)
            #expect(max == 20)
        } else {
            Issue.record("Expected intOutOfRange error")
        }
    }

    @Test("Int validation fails for value above range")
    func intValidationFailsAboveRange() {
        let value = 25
        let result = value.validated(in: 10...20)
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .intOutOfRange(_, let min, let max) = error {
            #expect(min == 10)
            #expect(max == 20)
        } else {
            Issue.record("Expected intOutOfRange error")
        }
    }

    // MARK: - Int Non-Negative Validation Tests

    @Test("Int non-negative validation accepts zero")
    func intNonNegativeValidationAcceptsZero() {
        let value = 0
        let result = value.validatedNonNegative()
        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated == 0)
    }

    @Test("Int non-negative validation accepts positive")
    func intNonNegativeValidationAcceptsPositive() {
        let value = 42
        let result = value.validatedNonNegative()
        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated == 42)
    }

    @Test("Int non-negative validation rejects negative")
    func intNonNegativeValidationRejectsNegative() {
        let value = -1
        let result = value.validatedNonNegative()
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        if case .intNegative = error {
            // Expected error type
        } else {
            Issue.record("Expected intNegative error")
        }
    }

    // MARK: - Validation Rules Constants Tests

    @Test("Validation rules null display max length is correct")
    func validationRulesNullDisplayMaxLength() {
        #expect(SettingsValidationRules.nullDisplayMaxLength == 20)
    }

    @Test("Validation rules default page size range is correct")
    func validationRulesDefaultPageSizeRange() {
        let range = SettingsValidationRules.defaultPageSizeRange
        #expect(range.lowerBound == 10)
        #expect(range.upperBound == 100_000)
    }

    @Test("Validation rules min non-negative is correct")
    func validationRulesMinNonNegative() {
        #expect(SettingsValidationRules.minNonNegative == 0)
    }

    // MARK: - Unicode Length Tests

    @Test("String validation handles multi-byte Unicode correctly")
    func stringValidationHandlesUnicode() {
        // NSString.length counts UTF-16 code units, not grapheme clusters
        // A flag emoji like 🇻🇳 is 4 UTF-16 code units but 1 grapheme cluster
        let input = String(repeating: "a", count: 9) + "🇻🇳"
        // With .count this would be 10 (9 chars + 1 emoji)
        // With NSString.length this is 13 (9 + 4 UTF-16 units for flag emoji)
        let result = input.validated(maxLength: 12)
        guard case .failure = result else {
            Issue.record("Expected failure for string exceeding UTF-16 maxLength")
            return
        }
    }
}
