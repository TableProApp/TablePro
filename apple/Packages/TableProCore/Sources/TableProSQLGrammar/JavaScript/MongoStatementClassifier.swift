import Foundation

public enum MongoStatementTier: Sendable, Equatable {
    case read
    case write
    case destructive
}

public struct MongoStatementVerdict: Sendable, Equatable {
    public let tier: MongoStatementTier
    public let reachesCode: Bool

    public init(tier: MongoStatementTier, reachesCode: Bool) {
        self.tier = tier
        self.reachesCode = reachesCode
    }

    static let read = MongoStatementVerdict(tier: .read, reachesCode: false)

    func escalated(with other: MongoStatementVerdict) -> MongoStatementVerdict {
        MongoStatementVerdict(tier: Self.worse(tier, other.tier), reachesCode: reachesCode || other.reachesCode)
    }

    private static func worse(_ lhs: MongoStatementTier, _ rhs: MongoStatementTier) -> MongoStatementTier {
        if lhs == .destructive || rhs == .destructive { return .destructive }
        if lhs == .write || rhs == .write { return .write }
        return .read
    }
}

// The plugin runs the text as JavaScript, so no scan of method names proves a read:
// `db.c.find(db.c[("delete" + "Many")]({}))` names only `find`. Only MongoStatementParser accepting all of it does.
public enum MongoStatementClassifier {
    // Each statement counts on its own and the worst wins. Sound however the split falls: a proven read is one
    // expression and its neighbours begin with `db`, so JavaScript cannot join two of them into anything else.
    public static func verdict(_ text: String, shadowsCollection: @escaping (String) -> Bool) -> MongoStatementVerdict {
        let text = StatementBlank.trimming(text)
        let statements = JavaScriptStatementScanner.locatedStatements(in: text)
        guard statements.count > 1 else { return statementVerdict(text, shadowsCollection: shadowsCollection) }
        return statements.reduce(MongoStatementVerdict.read) { worst, statement in
            worst.escalated(with: statementVerdict(statement.text, shadowsCollection: shadowsCollection))
        }
    }

    private static let destructiveMethods: Set<String> = [
        "drop", "dropdatabase", "dropindex", "dropindexes", "dropcollection", "deletemany", "remove",
        "removeall", "renamecollection"
    ]

    // What the destructive methods do by name, done through `runCommand`.
    private static let destructiveCommands: Set<String> = [
        "drop", "dropdatabase", "dropindexes", "delete", "renamecollection"
    ]

    // A pipeline may hold `$out` or `$merge` only as its last stage, so the key spelled exactly so is the whole test.
    private static let pipelineWriteStages: Set<String> = ["$out", "$merge"]

    // Server-side JavaScript, plus the two stages that write to a collection the statement names.
    private static let codeExecutionKeys: Set<String> = ["$where", "$function", "$accumulator", "$out", "$merge"]

    // The server accepts its own operators from any client, and rewrites `mapReduce` into two of them that run a
    // function: `$_internalJsEmit` and `$_internalJsReduce`. Nothing a person writes names one.
    private static let internalOperatorPrefix = "$_internal"

    private static let codeExecutionCalls: Set<String> = ["mapreduce", "eval"]

    // For text the grammar rejects, where a false alarm only stops an external client sending code nobody could read.
    private static let codeExecutionMarkers: [String] = [
        "$where", "$function", "$accumulator", "$_internal", "mapreduce", ".eval(", "$out", "$merge"
    ]

    private static func statementVerdict(
        _ text: String,
        shadowsCollection: @escaping (String) -> Bool
    ) -> MongoStatementVerdict {
        guard !MongoStatementParser.isTrivia(text) else { return .read }
        guard let statement = MongoStatementParser.parse(text, shadowsCollection: shadowsCollection) else {
            return unparsedVerdict(text)
        }
        return verdict(of: statement)
    }

    private static func verdict(of statement: MongoStatement) -> MongoStatementVerdict {
        let reachesCode = !statement.objectKeys.isDisjoint(with: codeExecutionKeys)
            || statement.objectKeys.contains { $0.hasPrefix(internalOperatorPrefix) }
            || statement.calls.contains { call in
                codeExecutionCalls.contains(call.name.lowercased())
                    || call.commandName.map { codeExecutionCalls.contains($0.lowercased()) } == true
            }
        let destroys = statement.calls.contains { call in
            destructiveMethods.contains(call.name.lowercased())
                || call.commandName.map { destructiveCommands.contains($0.lowercased()) } == true
        }
        if destroys {
            return MongoStatementVerdict(tier: .destructive, reachesCode: reachesCode)
        }
        let writesThroughPipeline = !statement.objectKeys.isDisjoint(with: pipelineWriteStages)
        guard statement.calls.allSatisfy(\.isRead), !writesThroughPipeline else {
            return MongoStatementVerdict(tier: .write, reachesCode: reachesCode)
        }
        return MongoStatementVerdict(tier: .read, reachesCode: reachesCode)
    }

    // Never a read. The scan only decides whether the confirmation warns that data goes away.
    private static func unparsedVerdict(_ text: String) -> MongoStatementVerdict {
        let lowered = javaScriptEscapesDecoded(text).lowercased()
        let reachesCode = codeExecutionMarkers.contains { lowered.contains($0) }
        let destroys = memberNames(in: lowered).contains { destructiveMethods.contains($0) }
        return MongoStatementVerdict(tier: destroys ? .destructive : .write, reachesCode: reachesCode)
    }

    // Identifiers after a `.` (spaces and a `?.` allowed between), and strings written straight inside `[`.
    private static func memberNames(in lowered: String) -> [String] {
        var names: [String] = []
        var scalars = lowered.unicodeScalars[...]
        var followsDot = false
        while let scalar = scalars.first {
            if isIdentifierScalar(scalar) {
                let name = String(String.UnicodeScalarView(scalars.prefix(while: isIdentifierScalar)))
                scalars = scalars.drop(while: isIdentifierScalar)
                if followsDot { names.append(name) }
                followsDot = false
                continue
            }
            scalars = scalars.dropFirst()
            switch scalar {
            case ".":
                followsDot = true
            case "?":
                continue
            case "[":
                let inner = scalars.drop { $0.properties.isWhitespace }
                guard let quote = inner.first, quote == "\"" || quote == "'" || quote == "`" else { break }
                let body = inner.dropFirst().prefix { $0 != quote }
                names.append(String(String.UnicodeScalarView(body)))
                scalars = inner.dropFirst(body.count + 2)
            default:
                if !scalar.properties.isWhitespace { followsDot = false }
            }
        }
        return names
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
    }

    // So a scan sees `dr\u006fp` as `drop`: `\xHH`, `\uHHHH` and `\u{H...}` written out as their characters.
    private static func javaScriptEscapesDecoded(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var decoded = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\\", let marker = scalars.first, marker == "x" || marker == "u" else {
                decoded.append(scalar)
                continue
            }
            let rest = scalars.dropFirst()
            let digits: Substring.UnicodeScalarView
            var consumed: Int
            if marker == "u", rest.first == "{" {
                digits = rest.dropFirst().prefix { $0 != "}" }
                consumed = digits.count + 2
            } else {
                let width = marker == "x" ? 2 : 4
                digits = rest.prefix(width)
                consumed = digits.count == width ? width : 0
            }
            guard consumed > 0, let value = UInt32(String(String.UnicodeScalarView(digits)), radix: 16),
                  let character = Unicode.Scalar(value)
            else {
                decoded.append(scalar)
                continue
            }
            consumed += 1
            decoded.append(character)
            scalars = scalars.dropFirst(consumed)
        }
        return String(decoded)
    }
}
