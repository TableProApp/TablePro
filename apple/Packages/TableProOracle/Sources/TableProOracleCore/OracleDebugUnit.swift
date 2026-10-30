import Foundation

public enum OracleDebugUnitKind: String, Sendable, Hashable, CaseIterable {
    case procedure = "PROCEDURE"
    case function = "FUNCTION"
    case package = "PACKAGE"
    case packageBody = "PACKAGE BODY"
    case trigger = "TRIGGER"
    case type = "TYPE"
    case typeBody = "TYPE BODY"

    // The middle of `$Oracle/<Kind>/<OWNER>/<NAME>`. Package, PackageBody, Procedure and Function are measured on
    // 23.26; Trigger, Type and TypeBody follow the same naming and are not.
    public var jdwpKind: String {
        switch self {
        case .procedure: return "Procedure"
        case .function: return "Function"
        case .package: return "Package"
        case .packageBody: return "PackageBody"
        case .trigger: return "Trigger"
        case .type: return "Type"
        case .typeBody: return "TypeBody"
        }
    }

    public init?(jdwpKind: String) {
        guard let kind = Self.allCases.first(where: { $0.jdwpKind == jdwpKind }) else { return nil }
        self = kind
    }

    // DBMS_DEBUG namespaces: 1 holds specs and top-level units, 2 bodies, 3 triggers.
    public var namespace: Int {
        switch self {
        case .procedure, .function, .package, .type: return 1
        case .packageBody, .typeBody: return 2
        case .trigger: return 3
        }
    }

    // DBMS_DEBUG's LibunitType values (the KGLT constants).
    public init?(namespace: Int, libunitType: Int) {
        switch (namespace, libunitType) {
        case (1, 7): self = .procedure
        case (1, 8): self = .function
        case (1, 9): self = .package
        case (1, 13): self = .type
        case (2, 11): self = .packageBody
        case (2, 14): self = .typeBody
        case (3, _): self = .trigger
        default: return nil
        }
    }

    public var hasSubprograms: Bool {
        self == .packageBody || self == .typeBody || self == .package || self == .type
    }

    // The statement that compiles the unit with debug information, without touching its other settings. A package
    // compiles only its body, so nothing that depends on the specification is invalidated.
    public func compileForDebugStatement(owner: String, name: String) -> String {
        let qualified = "\(OracleDebugUnit.quote(owner)).\(OracleDebugUnit.quote(name))"
        let tail = "COMPILE PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS"
        switch self {
        case .procedure: return "ALTER PROCEDURE \(qualified) \(tail)"
        case .function: return "ALTER FUNCTION \(qualified) \(tail)"
        case .package, .packageBody: return "ALTER PACKAGE \(qualified) COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS"
        case .trigger: return "ALTER TRIGGER \(qualified) \(tail)"
        case .type, .typeBody: return "ALTER TYPE \(qualified) COMPILE BODY PLSQL_OPTIMIZE_LEVEL=1 REUSE SETTINGS"
        }
    }
}

public struct OracleDebugUnit: Sendable, Hashable {
    public let owner: String
    public let name: String
    public let kind: OracleDebugUnitKind

    public init(owner: String, name: String, kind: OracleDebugUnitKind) {
        self.owner = owner
        self.name = name
        self.kind = kind
    }

    // `TYPE/OWNER/NAME`, each part with `%` and `/` escaped: a quoted Oracle name may hold either.
    public var identity: String {
        [kind.rawValue, owner, name].map(Self.escape).joined(separator: "/")
    }

    public init?(identity: String) {
        let parts = Self.split(identity)
        guard parts.count == 3, let kind = OracleDebugUnitKind(rawValue: parts[0]) else { return nil }
        self.init(owner: parts[1], name: parts[2], kind: kind)
    }

    // The body holds the code a package or type runs.
    public var codeUnit: OracleDebugUnit {
        switch kind {
        case .package: return OracleDebugUnit(owner: owner, name: name, kind: .packageBody)
        case .type: return OracleDebugUnit(owner: owner, name: name, kind: .typeBody)
        default: return self
        }
    }

    public var jdwpSignature: String {
        "L\(jdwpClassName);"
    }

    // The ClassMatch pattern, which is the class name without the `L` and `;`.
    public var jdwpClassName: String {
        "$Oracle/\(kind.jdwpKind)/\(owner)/\(name)"
    }

    // Nil for anonymous blocks, built-ins, Java classes, and the classes Oracle makes for local types, which carry
    // extra path components (`$Oracle/Function/PROBE/F_CALC/F_CALC/T_NUMS`).
    public init?(jdwpSignature: String) {
        guard jdwpSignature.hasPrefix("L$Oracle/"), jdwpSignature.hasSuffix(";") else { return nil }
        let path = jdwpSignature.dropFirst("L$Oracle/".count).dropLast()
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = OracleDebugUnitKind(jdwpKind: parts[0]),
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.init(owner: parts[1], name: parts[2], kind: kind)
    }

    public static func isAnonymousBlock(jdwpSignature: String) -> Bool {
        jdwpSignature.hasPrefix("L$Oracle/Block/")
    }

    // `L$Oracle/Builtin/NUMBER;` reads NUMBER; a local type reads its own name.
    public static func typeName(fromJDWPSignature signature: String) -> String {
        var text = Substring(signature)
        if text.hasPrefix("L") { text = text.dropFirst() }
        if text.hasSuffix(";") { text = text.dropLast() }
        return String(text.split(separator: "/").last ?? text)
    }

    public static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
    }

    public static func literal(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "''", options: .literal))'"
    }

    static func escape(_ part: String) -> String {
        part.replacingOccurrences(of: "%", with: "%25", options: .literal)
            .replacingOccurrences(of: "/", with: "%2F", options: .literal)
    }

    static func unescape(_ part: String) -> String {
        part.replacingOccurrences(of: "%2F", with: "/", options: .literal)
            .replacingOccurrences(of: "%25", with: "%", options: .literal)
    }

    static func split(_ identity: String) -> [String] {
        identity.split(separator: "/", omittingEmptySubsequences: false).map { unescape(String($0)) }
    }
}

// One public subprogram overload of a unit, or the standalone routine itself.
public struct OracleDebugEntry: Sendable, Hashable {
    public let unit: OracleDebugUnit
    public let subprogram: String
    public let subprogramID: Int

    public init(unit: OracleDebugUnit, subprogram: String, subprogramID: Int) {
        self.unit = unit
        self.subprogram = subprogram
        self.subprogramID = subprogramID
    }

    public var identity: String {
        unit.identity + "/" + OracleDebugUnit.escape(subprogram) + "/" + String(subprogramID)
    }

    public init?(identity: String) {
        let parts = OracleDebugUnit.split(identity)
        guard parts.count == 5, let kind = OracleDebugUnitKind(rawValue: parts[0]),
              let subprogramID = Int(parts[4]) else { return nil }
        self.init(
            unit: OracleDebugUnit(owner: parts[1], name: parts[2], kind: kind),
            subprogram: parts[3],
            subprogramID: subprogramID
        )
    }

    public var isPackaged: Bool { unit.kind.hasSubprograms }
}
