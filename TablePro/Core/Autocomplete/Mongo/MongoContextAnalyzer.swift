import Foundation

enum MongoCompletionPosition: Equatable {
    case statementStart
    case databaseMember
    case collectionMethod(collection: String)
    case filterDocument(collection: String?)
    case projectionDocument(collection: String?)
    case updateDocument
    case updatePipelineStage
    case plainDocument(collection: String?)
    case pipelineStage(collection: String?)
    case stageExpression(collection: String?)
    case suppressed
}

struct MongoContext: Equatable {
    let position: MongoCompletionPosition
    let prefix: String
    let prefixRange: NSRange
}

enum MongoContextAnalyzer {
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closeBrace = UInt16(UnicodeScalar("}").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)

    private struct Frame {
        let opener: UInt16
        let openIndex: Int
        let callee: String?
        var argumentIndex: Int
    }

    private struct ScanState {
        var frames: [Frame] = []
        var isInString = false
        var isInComment = false
    }

    static func analyze(text: NSString, cursor: Int) -> MongoContext {
        let bounded = max(0, min(cursor, text.length))
        let prefixRange = prefixRange(in: text, endingAt: bounded)
        let prefix = text.substring(with: prefixRange)
        let state = scan(text: text, upTo: prefixRange.location)

        return MongoContext(
            position: position(for: state, text: text, tokenStart: prefixRange.location),
            prefix: prefix,
            prefixRange: prefixRange
        )
    }

    static func prefixRange(in text: NSString, endingAt offset: Int) -> NSRange {
        var start = max(0, min(offset, text.length))

        while start > 0 {
            let character = text.character(at: start - 1)
            guard isTokenCharacter(character) else { break }
            start -= 1
        }

        if start > 0, text.character(at: start - 1) == dollar {
            start -= 1
            if start > 0, text.character(at: start - 1) == dollar {
                start -= 1
            }
        }

        return NSRange(location: start, length: offset - start)
    }

    private static func isTokenCharacter(_ character: UInt16) -> Bool {
        (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || (character >= 0x30 && character <= 0x39)
            || character == underscore
    }

    private static func isIdentifierStart(_ character: UInt16) -> Bool {
        (character >= 0x41 && character <= 0x5A) || (character >= 0x61 && character <= 0x7A)
            || character == underscore || character == dollar
    }

    private static func scan(text: NSString, upTo end: Int) -> ScanState {
        var state = ScanState()
        var index = 0
        var stringDelimiter: UInt16 = 0
        var isInLineComment = false
        var isInBlockComment = false

        while index < end {
            let character = text.character(at: index)

            if isInLineComment {
                if character == newline { isInLineComment = false }
                index += 1
                continue
            }

            if isInBlockComment {
                if character == star, index + 1 < end, text.character(at: index + 1) == slash {
                    isInBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if stringDelimiter != 0 {
                if character == backslash {
                    index += 2
                    continue
                }
                if character == stringDelimiter { stringDelimiter = 0 }
                index += 1
                continue
            }

            if character == slash, index + 1 < end {
                let next = text.character(at: index + 1)
                if next == slash {
                    isInLineComment = true
                    index += 2
                    continue
                }
                if next == star {
                    isInBlockComment = true
                    index += 2
                    continue
                }
            }

            if character == singleQuote || character == doubleQuote || character == backtick {
                stringDelimiter = character
                index += 1
                continue
            }

            switch character {
            case openParen:
                state.frames.append(
                    Frame(
                        opener: openParen,
                        openIndex: index,
                        callee: identifier(in: text, endingBefore: index),
                        argumentIndex: 0
                    )
                )
            case openBrace:
                state.frames.append(Frame(opener: openBrace, openIndex: index, callee: nil, argumentIndex: 0))
            case openBracket:
                state.frames.append(Frame(opener: openBracket, openIndex: index, callee: nil, argumentIndex: 0))
            case closeParen, closeBrace, closeBracket:
                if !state.frames.isEmpty { state.frames.removeLast() }
            case comma:
                if !state.frames.isEmpty { state.frames[state.frames.count - 1].argumentIndex += 1 }
            default:
                break
            }

            index += 1
        }

        state.isInString = stringDelimiter != 0
        state.isInComment = isInLineComment || isInBlockComment
        return state
    }

    private static func identifier(in text: NSString, endingBefore index: Int) -> String? {
        var end = index
        while end > 0, text.character(at: end - 1) == UInt16(UnicodeScalar(" ").value) {
            end -= 1
        }
        var start = end
        while start > 0, isTokenCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        guard start < end, isIdentifierStart(text.character(at: start)) else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func position(for state: ScanState, text: NSString, tokenStart: Int) -> MongoCompletionPosition {
        if state.isInComment { return .suppressed }

        if state.frames.isEmpty, !state.isInString {
            return topLevelPosition(text: text, tokenStart: tokenStart)
        }

        guard let callFrameIndex = state.frames.lastIndex(where: { $0.opener == openParen }),
              let callee = state.frames[callFrameIndex].callee else {
            return state.isInString ? .suppressed : .statementStart
        }

        let argumentIndex = state.frames[callFrameIndex].argumentIndex
        let nested = Array(state.frames.suffix(from: callFrameIndex + 1))
        let collection = collectionName(in: text, endingBefore: state.frames[callFrameIndex].openIndex)

        if state.isInString, nested.isEmpty { return .suppressed }

        switch callee {
        case "find", "findOne":
            if argumentIndex == 0 { return .filterDocument(collection: collection) }
            if argumentIndex == 1 { return .projectionDocument(collection: collection) }
            return .suppressed
        case "countDocuments", "deleteOne", "deleteMany", "findOneAndDelete", "distinct":
            return argumentIndex == 0 || callee == "distinct"
                ? .filterDocument(collection: collection)
                : .suppressed
        case "updateOne", "updateMany", "findOneAndUpdate":
            if argumentIndex == 0 { return .filterDocument(collection: collection) }
            if argumentIndex == 1 {
                return nested.first?.opener == openBracket ? .updatePipelineStage : .updateDocument
            }
            return .suppressed
        case "replaceOne", "findOneAndReplace":
            if argumentIndex == 0 { return .filterDocument(collection: collection) }
            if argumentIndex == 1 { return .plainDocument(collection: collection) }
            return .suppressed
        case "insertOne", "insertMany":
            return .plainDocument(collection: collection)
        case "aggregate":
            guard nested.first?.opener == openBracket else { return .suppressed }
            let documentDepth = nested.filter { $0.opener == openBrace }.count
            return documentDepth <= 1
                ? .pipelineStage(collection: collection)
                : .stageExpression(collection: collection)
        case "createIndex", "createIndexes", "dropIndex", "hideIndex", "unhideIndex":
            return .plainDocument(collection: collection)
        default:
            return .suppressed
        }
    }

    private static func collectionName(in text: NSString, endingBefore parenIndex: Int) -> String? {
        var end = parenIndex
        var segments: [String] = []

        while end > 0 {
            var start = end
            while start > 0, isTokenCharacter(text.character(at: start - 1)) {
                start -= 1
            }
            guard start < end else { break }
            segments.insert(text.substring(with: NSRange(location: start, length: end - start)), at: 0)
            guard start > 0, text.character(at: start - 1) == dot else { break }
            end = start - 1
        }

        guard segments.count >= 3, segments[0] == "db" else { return nil }
        return segments[1 ..< (segments.count - 1)].joined(separator: ".")
    }

    private static func topLevelPosition(text: NSString, tokenStart: Int) -> MongoCompletionPosition {
        guard tokenStart > 0, text.character(at: tokenStart - 1) == dot else {
            return .statementStart
        }

        var end = tokenStart - 1
        var segments: [String] = []

        while end > 0 {
            var start = end
            while start > 0, isTokenCharacter(text.character(at: start - 1)) {
                start -= 1
            }
            guard start < end else { break }
            segments.insert(text.substring(with: NSRange(location: start, length: end - start)), at: 0)
            guard start > 0, text.character(at: start - 1) == dot else { break }
            end = start - 1
        }

        guard segments.first == "db" else { return .statementStart }
        if segments.count == 1 { return .databaseMember }
        return .collectionMethod(collection: segments[1...].joined(separator: "."))
    }
}
