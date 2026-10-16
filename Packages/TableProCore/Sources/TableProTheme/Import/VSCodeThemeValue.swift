import Foundation

// A value from a file another editor wrote: a VS Code theme (JSON with comments) or a TextMate
// theme (a property list). The import reads it leniently, the way VS Code does.
internal indirect enum VSCodeThemeValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([VSCodeThemeValue])
    case object([String: VSCodeThemeValue])

    // Arrays and objects, counting the outermost. A real theme nests about 5. Conversion recurses once
    // per level, and Foundation's own cap of 512 overflowed a 512 KB thread stack in a debug build.
    internal static let maximumDepth = 32

    // A tmTheme within the rule cap holds well under this many values. The budget also stops a graph
    // whose containers repeat, which converts into a tree exponentially larger than the file.
    internal static let maximumPropertyListValues = 100_000

    // JSON5 is a superset of the JSONC VS Code reads, and the mode does not depend on the OS release.
    internal static func parse(_ data: Data) throws -> VSCodeThemeValue {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        do {
            return try decoder.decode(VSCodeThemeValue.self, from: data)
        } catch let error as ThemeLoadError {
            throw error
        } catch let DecodingError.dataCorrupted(context) {
            let underlying = context.underlyingError as NSError?
            throw ThemeLoadError.malformedJSON(detail: underlying?.userInfo[NSDebugDescriptionErrorKey] as? String)
        } catch {
            throw ThemeLoadError.malformedJSON(detail: nil)
        }
    }

    // Nil past the depth cap or the value budget.
    internal init?(propertyList value: Any) {
        var remainingValues = Self.maximumPropertyListValues
        guard let converted = Self.converted(propertyList: value, depth: 0, remainingValues: &remainingValues) else {
            return nil
        }
        self = converted
    }

    private static func converted(propertyList value: Any, depth: Int, remainingValues: inout Int) -> VSCodeThemeValue? {
        guard remainingValues > 0 else { return nil }
        remainingValues -= 1

        if let string = value as? String {
            return .string(string)
        }
        if let dictionary = value as? [String: Any] {
            guard depth < maximumDepth else { return nil }
            var object: [String: VSCodeThemeValue] = [:]
            for (key, item) in dictionary {
                guard let child = converted(propertyList: item, depth: depth + 1, remainingValues: &remainingValues) else {
                    return nil
                }
                object[key] = child
            }
            return .object(object)
        }
        if let array = value as? [Any] {
            guard depth < maximumDepth else { return nil }
            var items: [VSCodeThemeValue] = []
            for item in array {
                guard let child = converted(propertyList: item, depth: depth + 1, remainingValues: &remainingValues) else {
                    return nil
                }
                items.append(child)
            }
            return .array(items)
        }
        if let number = value as? NSNumber {
            return .number(number.doubleValue)
        }
        return .null
    }

    internal var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    internal var objectValue: [String: VSCodeThemeValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    internal var arrayValue: [VSCodeThemeValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    // VS Code tests most fields with JavaScript truthiness, so an empty string or a zero means unset.
    internal var isTruthy: Bool {
        switch self {
        case let .string(value): return !value.isEmpty
        case let .number(value): return value != 0 && !value.isNaN
        case let .bool(value): return value
        case .null: return false
        case .array, .object: return true
        }
    }
}

extension VSCodeThemeValue: Decodable {
    // Elements decode with `try`, not `try?`, so a depth refusal deep inside reaches the caller rather
    // than turning into a type mismatch one level up.
    internal init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if decoder.codingPath.count >= Self.maximumDepth {
            throw ThemeLoadError.nestingTooDeep(limit: Self.maximumDepth)
        } else if var elements = try? decoder.unkeyedContainer() {
            var items: [VSCodeThemeValue] = []
            while !elements.isAtEnd {
                items.append(try elements.decode(VSCodeThemeValue.self))
            }
            self = .array(items)
        } else {
            let members = try decoder.container(keyedBy: VSCodeThemeKey.self)
            var object: [String: VSCodeThemeValue] = [:]
            for key in members.allKeys {
                object[key.stringValue] = try members.decode(VSCodeThemeValue.self, forKey: key)
            }
            self = .object(object)
        }
    }
}

private struct VSCodeThemeKey: CodingKey {
    let stringValue: String

    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
