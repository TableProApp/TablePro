//
//  RowGenerationDefaults.swift
//  TablePro
//

import Foundation

// The generator a column starts with, read from its type first and its name second.
internal enum RowGenerationDefaults {
    internal static func settings(
        for column: RowGenerationColumn,
        in table: RowGenerationTable,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RowGeneratorSettings {
        let (start, end) = dateRange(now: now, calendar: calendar)
        var settings = RowGeneratorSettings(kind: .serverDefault, dateStart: start, dateEnd: end)
        let tokens = nameTokens(column.name)
        applyNumericDefaults(to: &settings, column: column, table: table, tokens: tokens)
        applyTextDefaults(to: &settings, column: column, tokens: tokens)
        if case .enumeration(let labels) = column.valueClass {
            settings.values = labels
        }
        settings.kind = kind(for: column, tokens: tokens)
        if settings.kind == .pattern {
            settings.pattern = pattern(for: tokens)
        }
        return settings
    }

    internal static func kind(for column: RowGenerationColumn) -> RowGeneratorKind {
        kind(for: column, tokens: nameTokens(column.name))
    }

    private static func kind(for column: RowGenerationColumn, tokens: [String]) -> RowGeneratorKind {
        guard column.ownership == .none else { return .serverDefault }
        if column.reference != nil { return .reference }
        switch column.valueClass {
        case .enumeration: return .list
        case .boolean: return .boolean
        case .uuid: return .uuid
        case .json: return .json
        case .date: return .date
        case .time: return .time
        case .timestamp: return .dateTime
        case .integer: return column.isUnique ? .sequence : .integerRange
        case .decimal, .floatingPoint: return .decimalRange
        case .text: return textKind(tokens: tokens)
        case .unsupported: return .serverDefault
        }
    }

    private static func textKind(tokens: [String]) -> RowGeneratorKind {
        let joined = tokens.joined()
        func has(_ words: String...) -> Bool { words.contains { tokens.contains($0) } }
        if has("email", "mail") { return .email }
        if joined.contains("firstname") || has("forename", "fname") || joined.contains("givenname") { return .firstName }
        if joined.contains("lastname") || has("surname", "lname") || joined.contains("familyname") { return .lastName }
        if has("phone", "mobile", "tel", "telephone", "fax", "cell") { return .phone }
        if has("address", "street", "addr") { return .streetAddress }
        if has("city", "town") { return .city }
        if has("country") { return .country }
        if has("uuid", "guid") { return .uuid }
        if has("zip", "postal", "postcode", "url", "website", "homepage", "link", "sku", "code") { return .pattern }
        if joined == "name" || joined.hasSuffix("fullname") || has("author") { return .fullName }
        let people = ["display", "contact", "customer", "user", "owner", "employee", "person", "member", "client"]
        if has("name"), tokens.contains(where: people.contains) { return .fullName }
        return .text
    }

    private static func pattern(for tokens: [String]) -> String {
        if tokens.contains(where: { ["zip", "postal", "postcode"].contains($0) }) { return "#####" }
        if tokens.contains(where: { ["url", "website", "homepage", "link"].contains($0) }) {
            return "https://example.com/????????"
        }
        return "???-####"
    }

    private static func applyNumericDefaults(
        to settings: inout RowGeneratorSettings,
        column: RowGenerationColumn,
        table: RowGenerationTable,
        tokens: [String]
    ) {
        func has(_ words: String...) -> Bool { words.contains { tokens.contains($0) } }
        switch column.valueClass {
        case .integer(let minimum, let maximum):
            var range: ClosedRange<Int64> = 1...1_000
            if has("age") {
                range = 18...90
            } else if has("year") {
                range = 1_990...2_030
            } else if has("quantity", "qty", "count", "stock") {
                range = 0...100
            }
            settings.integerMinimum = min(max(range.lowerBound, minimum), maximum)
            settings.integerMaximum = max(min(range.upperBound, maximum), settings.integerMinimum)
            if column.isUnique {
                let next = (table.keyMaximums[column.name] ?? 0).addingReportingOverflow(1)
                settings.integerMinimum = next.overflow ? maximum : min(max(next.partialValue, minimum), maximum)
                settings.integerMaximum = maximum
            }
        case .decimal(let precision, let scale):
            settings.decimalScale = scale ?? 2
            var range: ClosedRange<Double> = 0...1_000
            if has("lat", "latitude") {
                range = -90...90
                settings.decimalScale = min(6, scale ?? 6)
            } else if has("lng", "lon", "long", "longitude") {
                range = -180...180
                settings.decimalScale = min(6, scale ?? 6)
            } else if has("rating", "score") {
                range = 0...5
                settings.decimalScale = min(1, scale ?? 1)
            } else if has("price", "amount", "cost", "total", "salary", "balance", "fee") {
                range = 1...1_000
            }
            let limit = RowGenerationValidation.decimalLimit(precision: precision, scale: scale)
            settings.decimalMinimum = max(range.lowerBound, -limit)
            settings.decimalMaximum = min(range.upperBound, limit)
            settings.integerMinimum = Int64(settings.decimalMinimum.rounded(.up))
            settings.integerMaximum = Int64(settings.decimalMaximum.rounded(.down))
        case .floatingPoint:
            settings.decimalScale = has("lat", "latitude", "lng", "lon", "longitude") ? 6 : 2
            settings.decimalMinimum = has("lat", "latitude") ? -90 : (has("lng", "lon", "longitude") ? -180 : 0)
            settings.decimalMaximum = has("lat", "latitude") ? 90 : (has("lng", "lon", "longitude") ? 180 : 1_000)
        default:
            break
        }
    }

    private static func applyTextDefaults(
        to settings: inout RowGeneratorSettings,
        column: RowGenerationColumn,
        tokens: [String]
    ) {
        func has(_ words: String...) -> Bool { words.contains { tokens.contains($0) } }
        var range = 5...30
        if has("description", "notes", "note", "bio", "comment", "comments", "body", "content", "summary", "message") {
            range = 20...200
        } else if has("title", "subject", "headline", "label") {
            range = 10...60
        }
        let cap = column.maxLength ?? Int.max
        settings.maxLength = max(1, min(range.upperBound, cap))
        settings.minLength = min(range.lowerBound, settings.maxLength)
    }

    // Absolute dates rather than "the last five years", so the same settings give the same rows next year too.
    private static func dateRange(now: Date, calendar: Calendar) -> (Date, Date) {
        let year = calendar.component(.year, from: now)
        let start = calendar.date(from: DateComponents(year: year - 4, month: 1, day: 1)) ?? now
        let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now
        return (start, end)
    }

    // `customerEmail`, `customer_email` and `CUSTOMER-EMAIL` all read as ["customer", "email"].
    internal static func nameTokens(_ name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousIsLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { tokens.append(current.lowercased()) }
                current = ""
                previousIsLower = false
                continue
            }
            if character.isUppercase, previousIsLower, !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousIsLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}
