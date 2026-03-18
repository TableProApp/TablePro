//
//  CaptureModifiers.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/24/24.
//

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokenModifiers

/// A collection of possible syntax capture modifiers. Represented by an integer for memory efficiency, and with the
/// ability to convert to and from strings for ease of use with tools.
///
/// These are useful for helping differentiate between similar types of syntax. Eg two variables may be declared like
/// ```swift
/// var a = 1
/// let b = 1
/// ```
/// ``CaptureName`` will represent both these later in code, but combined ``CaptureModifier`` themes can differentiate
/// between constants (`b` in the example) and regular variables (`a` in the example).
///
/// This is `Int8` raw representable for memory considerations. In large documents there can be *lots* of these created
/// and passed around, so representing them with a single integer is preferable to a string to save memory.
///
public enum CaptureModifier: Int8, CaseIterable, Sendable {
    case declaration
    case definition
    case readonly
    case `static`
    case deprecated
    case abstract
    case async
    case modification
    case documentation
    case defaultLibrary

    public var stringValue: String {
        switch self {
        case .declaration:
            return "declaration"
        case .definition:
            return "definition"
        case .readonly:
            return "readonly"
        case .static:
            return "static"
        case .deprecated:
            return "deprecated"
        case .abstract:
            return "abstract"
        case .async:
            return "async"
        case .modification:
            return "modification"
        case .documentation:
            return "documentation"
        case .defaultLibrary:
            return "defaultLibrary"
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func fromString(_ string: String) -> CaptureModifier? {
        switch string {
        case "declaration":
            return .declaration
        case "definition":
            return .definition
        case "readonly":
            return .readonly
        case "static`":
            return .static
        case "deprecated":
            return .deprecated
        case "abstract":
            return .abstract
        case "async":
            return .async
        case "modification":
            return .modification
        case "documentation":
            return .documentation
        case "defaultLibrary":
            return .defaultLibrary
        default:
            return nil
        }
    }
}

extension CaptureModifier: CustomDebugStringConvertible {
    public var debugDescription: String { stringValue }
}
