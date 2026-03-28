//
//  MariaDBJsonDetectionTests.swift
//  TableProTests
//
//  Tests the app-side classification and formatting pipeline for MariaDB JSON scenarios.
//  MariaDB stores JSON as LONGTEXT with utf8mb4_bin collation. The driver uses
//  mariadb_field_attr to detect JSON; when that succeeds, it returns "JSON".
//  When it fails (intermittent), the charset fallback causes it to return "LONGTEXT"
//  instead of "BLOB". These tests verify the app handles both paths correctly.
//

import Foundation
@testable import TablePro
import Testing

@Suite("MariaDB JSON Detection")
struct MariaDBJsonDetectionTests {
    private let classifier = ColumnTypeClassifier()

    // MARK: - Classifier: Driver returns "JSON" (mariadb_field_attr succeeded)

    @Test("JSON type name classifies as json")
    func jsonTypeNameClassifiesAsJson() {
        let result = classifier.classify(rawTypeName: "JSON")
        #expect(result.isJsonType)
    }

    @Test("JSON classified type is not blob")
    func jsonIsNotBlob() {
        let result = classifier.classify(rawTypeName: "JSON")
        #expect(!result.isBlobType)
    }

    // MARK: - Classifier: Driver returns "LONGTEXT" (mariadb_field_attr failed, charset fallback)

    @Test("LONGTEXT classifies as text, not blob")
    func longtextClassifiesAsText() {
        let result = classifier.classify(rawTypeName: "LONGTEXT")
        if case .text = result {
            // expected
        } else {
            Issue.record("LONGTEXT should classify as .text, got \(result)")
        }
    }

    @Test("LONGTEXT is not json type")
    func longtextIsNotJsonType() {
        let result = classifier.classify(rawTypeName: "LONGTEXT")
        #expect(!result.isJsonType)
    }

    @Test("LONGTEXT is not blob type")
    func longtextIsNotBlobType() {
        let result = classifier.classify(rawTypeName: "LONGTEXT")
        #expect(!result.isBlobType)
    }

    // MARK: - Classifier: True binary types still work

    @Test("BLOB classifies as blob")
    func blobClassifiesAsBlob() {
        let result = classifier.classify(rawTypeName: "BLOB")
        #expect(result.isBlobType)
    }

    @Test("LONGBLOB classifies as blob")
    func longblobClassifiesAsBlob() {
        let result = classifier.classify(rawTypeName: "LONGBLOB")
        #expect(result.isBlobType)
    }

    @Test("MEDIUMBLOB classifies as blob")
    func mediumblobClassifiesAsBlob() {
        let result = classifier.classify(rawTypeName: "MEDIUMBLOB")
        #expect(result.isBlobType)
    }

    @Test("TINYBLOB classifies as blob")
    func tinyblobClassifiesAsBlob() {
        let result = classifier.classify(rawTypeName: "TINYBLOB")
        #expect(result.isBlobType)
    }

    // MARK: - BlobFormattingService: formatting requirements

    @Suite("Blob Formatting Requirements")
    @MainActor
    struct BlobFormattingTests {
        @Test("JSON type does not require blob formatting")
        func jsonDoesNotRequireBlobFormatting() {
            let columnType = ColumnType.json(rawType: "JSON")
            #expect(!BlobFormattingService.shared.requiresFormatting(columnType: columnType))
        }

        @Test("LONGTEXT type does not require blob formatting")
        func longtextDoesNotRequireBlobFormatting() {
            let columnType = ColumnType.text(rawType: "LONGTEXT")
            #expect(!BlobFormattingService.shared.requiresFormatting(columnType: columnType))
        }

        @Test("BLOB type requires blob formatting")
        func blobRequiresBlobFormatting() {
            let columnType = ColumnType.blob(rawType: "BLOB")
            #expect(BlobFormattingService.shared.requiresFormatting(columnType: columnType))
        }

        @Test("LONGBLOB type requires blob formatting")
        func longblobRequiresBlobFormatting() {
            let columnType = ColumnType.blob(rawType: "LONGBLOB")
            #expect(BlobFormattingService.shared.requiresFormatting(columnType: columnType))
        }
    }

    // MARK: - CellDisplayFormatter: JSON vs BLOB display

    @Suite("Cell Display Formatting")
    @MainActor
    struct CellDisplayTests {
        @Test("JSON type value not hex-formatted in grid")
        func jsonValueNotHexFormatted() {
            let jsonValue = "{\"name\":\"test\"}"
            let columnType = ColumnType.json(rawType: "JSON")
            let display = CellDisplayFormatter.format(jsonValue, columnType: columnType)
            #expect(display == jsonValue)
        }

        @Test("Text type value not hex-formatted in grid")
        func textValueNotHexFormatted() {
            let textValue = "{\"name\":\"test\"}"
            let columnType = ColumnType.text(rawType: "LONGTEXT")
            let display = CellDisplayFormatter.format(textValue, columnType: columnType)
            #expect(display == textValue)
        }

        @Test("Blob type value is hex-formatted in grid")
        func blobValueIsHexFormatted() {
            let blobValue = "hello"
            let columnType = ColumnType.blob(rawType: "BLOB")
            let display = CellDisplayFormatter.format(blobValue, columnType: columnType)
            #expect(display != blobValue)
        }

        @Test("JSON value with newlines is sanitized but not hex-formatted")
        func jsonWithNewlinesSanitized() {
            let jsonValue = "{\n  \"name\": \"test\"\n}"
            let columnType = ColumnType.json(rawType: "JSON")
            let display = CellDisplayFormatter.format(jsonValue, columnType: columnType)
            // Newlines replaced by sanitizedForCellDisplay, but no hex encoding
            #expect(display?.contains("0x") != true)
            #expect(display?.contains("name") == true)
        }
    }

    // MARK: - ColumnType properties for MariaDB scenarios

    @Test("JSON type has correct display name")
    func jsonDisplayName() {
        let columnType = ColumnType.json(rawType: "JSON")
        #expect(columnType.displayName == "JSON")
    }

    @Test("LONGTEXT is recognized as long text")
    func longtextIsLongText() {
        let columnType = ColumnType.text(rawType: "LONGTEXT")
        #expect(columnType.isLongText)
    }

    @Test("LONGTEXT is recognized as very long text")
    func longtextIsVeryLongText() {
        let columnType = ColumnType.text(rawType: "LONGTEXT")
        #expect(columnType.isVeryLongText)
    }

    @Test("JSON type is not long text")
    func jsonIsNotLongText() {
        let columnType = ColumnType.json(rawType: "JSON")
        #expect(!columnType.isLongText)
    }

    @Test("JSON badge label is json")
    func jsonBadgeLabel() {
        let columnType = ColumnType.json(rawType: "JSON")
        #expect(columnType.badgeLabel == "json")
    }

    @Test("LONGTEXT badge label is string")
    func longtextBadgeLabel() {
        let columnType = ColumnType.text(rawType: "LONGTEXT")
        #expect(columnType.badgeLabel == "string")
    }

    @Test("BLOB badge label is binary")
    func blobBadgeLabel() {
        let columnType = ColumnType.blob(rawType: "BLOB")
        #expect(columnType.badgeLabel == "binary")
    }
}
