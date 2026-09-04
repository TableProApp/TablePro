//
//  CaptureNames.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 16.08.22.
//

/// A collection of possible syntax capture types. Represented by an integer for memory efficiency, and with the
/// ability to convert to and from strings for ease of use with tools.
///
/// This is `Int8` raw representable for memory considerations. In large documents there can be *lots* of these created
/// and passed around, so representing them with a single integer is preferable to a string to save memory.
///
public enum CaptureName: Int8, CaseIterable, Sendable {
    case include
    case constructor
    case keyword
    case boolean
    case `repeat`
    case conditional
    case tag
    case comment
    case variable
    case property
    case function
    case method
    case number
    case float
    case string
    case type
    case parameter
    case typeAlternate
    case variableBuiltin
    case keywordReturn
    case keywordFunction
    case `operator`
    case constant

    var alternate: CaptureName {
        switch self {
        case .type:
            return .typeAlternate
        default:
            return self
        }
    }

    /// Returns a specific capture name case from a given string.
    /// - Note: See ``CaptureName`` docs for why this enum isn't a raw representable.
    /// - Parameter string: A string to get the capture name from
    /// - Returns: A `CaptureNames` case
    public static func fromString(_ string: String?) -> CaptureName? {
        guard let string else { return nil }
        return canonical(string) ?? grammarAlias(string)
    }

    /// The names this editor's own vocabulary uses, matched exactly.
    private static func canonical(_ string: String) -> CaptureName? {
        switch string {
        case "include":
            return .include
        case "constructor":
            return .constructor
        case "keyword":
            return .keyword
        case "boolean":
            return .boolean
        case "repeat":
            return .repeat
        case "conditional":
            return .conditional
        case "tag":
            return .tag
        case "comment":
            return .comment
        case "variable":
            return .variable
        case "property":
            return .property
        case "function":
            return .function
        case "method":
            return .method
        case "number":
            return .number
        case "float":
            return .float
        case "string":
            return .string
        case "type":
            return .type
        case "parameter":
            return .parameter
        case "type_alternate":
            return .typeAlternate
        case "variable.builtin":
            return .variableBuiltin
        case "keyword.return":
            return .keywordReturn
        case "keyword.function":
            return .keywordFunction
        case "operator":
            return .operator
        case "constant":
            return .constant
        default:
            return nil
        }
    }

    /// The nvim-treesitter capture names the bundled grammars emit, mapped onto this editor's vocabulary.
    ///
    /// A name absent from both this table and ``canonical(_:)`` carries no colour at all, so
    /// `SyntaxHighlightingTests` fails on any name a bundled `highlights` query emits that neither
    /// table answers and ``unstyledGrammarCaptures`` does not list. An `injections` query is exempt:
    /// its captures name a range for the injection engine rather than for the palette.
    private static func grammarAlias(_ string: String) -> CaptureName? {
        switch string {
        case "keyword.operator", "attribute", "storageclass", "type.qualifier":
            return .keyword
        case "type.builtin":
            return .type
        case "function.call", "function.builtin":
            return .function
        case "function.method":
            return .method
        case "constant.builtin":
            return .constant
        case "string.special", "string.special.key":
            return .string
        default:
            return nil
        }
    }

    /// Capture names a bundled grammar emits that are deliberately left without a colour.
    ///
    /// `spell` and `embedded` mark a range for another tool rather than for the palette, and both sit
    /// on a range another capture already colours. `escape` sits inside a string that is already
    /// coloured. `field` would put every column identifier on the variable colour. `punctuation`
    /// keeps brackets and delimiters at the plain text colour, which is what VS Code and TablePlus
    /// both do, and spares a dense viewport 440 of its 1560 highlight ranges.
    public static let unstyledGrammarCaptures: Set<String> = [
        "field",
        "spell",
        "escape",
        "embedded",
        "punctuation.bracket",
        "punctuation.delimiter",
        "punctuation.special",
    ]

    /// See ``CaptureName`` docs for why this enum isn't a raw representable.
    var stringValue: String {
        switch self {
        case .include:
            return "include"
        case .constructor:
            return "constructor"
        case .keyword:
            return "keyword"
        case .boolean:
            return "boolean"
        case .repeat:
            return "repeat"
        case .conditional:
            return "conditional"
        case .tag:
            return "tag"
        case .comment:
            return "comment"
        case .variable:
            return "variable"
        case .property:
            return "property"
        case .function:
            return "function"
        case .method:
            return "method"
        case .number:
            return "number"
        case .float:
            return "float"
        case .string:
            return "string"
        case .type:
            return "type"
        case .parameter:
            return "parameter"
        case .typeAlternate:
            return "typeAlternate"
        case .variableBuiltin:
            return "variableBuiltin"
        case .keywordReturn:
            return "keywordReturn"
        case .keywordFunction:
            return "keywordFunction"
        case .operator:
            return "operator"
        case .constant:
            return "constant"
        }
    }
}

extension CaptureName: CustomDebugStringConvertible {
    public var debugDescription: String { stringValue }
}
