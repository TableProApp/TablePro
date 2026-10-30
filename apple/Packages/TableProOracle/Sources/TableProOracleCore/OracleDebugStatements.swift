import Foundation

public enum OracleDebugStatements {
    // MARK: - Catalog

    public static func targets(owner: String) -> String {
        """
        SELECT OBJECT_NAME, OBJECT_TYPE
        FROM SYS.ALL_OBJECTS
        WHERE OWNER = \(OracleDebugUnit.literal(owner))
          AND OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION', 'PACKAGE BODY')
        ORDER BY OBJECT_TYPE, OBJECT_NAME
        """
    }

    // Debug information exists when the unit was compiled with PLSQL_DEBUG or at PLSQL_OPTIMIZE_LEVEL 1 or lower.
    // At level 2 SET_BREAKPOINT still answers success and never fires (measured).
    public static func readiness(of unit: OracleDebugUnit) -> String {
        """
        SELECT PLSQL_OPTIMIZE_LEVEL, PLSQL_DEBUG
        FROM SYS.ALL_PLSQL_OBJECT_SETTINGS
        WHERE OWNER = \(OracleDebugUnit.literal(unit.owner))
          AND NAME = \(OracleDebugUnit.literal(unit.name))
          AND TYPE = \(OracleDebugUnit.literal(unit.codeUnit.kind.rawValue))
        """
    }

    public enum Readiness: Sendable, Equatable {
        case ready
        case needsDebugCompile
        case notVisible
    }

    public static func readiness(fromRow row: [String?]?) -> Readiness {
        guard let row else { return .notVisible }
        let level = row.first.flatMap { $0 }.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let debug = (row.count > 1 ? row[1] : nil)?.uppercased() == "TRUE"
        if debug { return .ready }
        if let level, level <= 1 { return .ready }
        return .needsDebugCompile
    }

    public static func privileges(of unit: OracleDebugUnit) -> String {
        """
        SELECT SYS_CONTEXT('USERENV', 'SESSION_USER'),
          (SELECT COUNT(*) FROM SYS.SESSION_PRIVS WHERE PRIVILEGE = 'DEBUG CONNECT SESSION'),
          (SELECT COUNT(*) FROM SYS.SESSION_PRIVS WHERE PRIVILEGE = 'DEBUG ANY PROCEDURE'),
          (SELECT COUNT(*) FROM SYS.ALL_TAB_PRIVS
            WHERE TABLE_SCHEMA = \(OracleDebugUnit.literal(unit.owner))
              AND TABLE_NAME = \(OracleDebugUnit.literal(unit.name))
              AND PRIVILEGE = 'DEBUG')
        FROM SYS.DUAL
        """
    }

    public enum MissingPrivilege: Sendable, Equatable {
        case debugConnectSession(user: String)
        case debugOnObject(user: String)
    }

    public static func missingPrivilege(fromRow row: [String?], unit: OracleDebugUnit) -> MissingPrivilege? {
        func count(_ index: Int) -> Int {
            (row.count > index ? row[index] : nil).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        }
        let user = (row.first ?? nil) ?? ""
        if count(1) == 0 { return .debugConnectSession(user: user) }
        if unit.owner != user, count(2) == 0, count(3) == 0 { return .debugOnObject(user: user) }
        return nil
    }

    // One row per public subprogram and argument; a subprogram without arguments comes back once with NULLs.
    public static func entryPoints(of unit: OracleDebugUnit) -> String {
        let owner = OracleDebugUnit.literal(unit.owner)
        let name = OracleDebugUnit.literal(unit.name)
        let subprograms: String
        if unit.kind.hasSubprograms {
            subprograms = "p.OBJECT_TYPE = 'PACKAGE' AND p.PROCEDURE_NAME IS NOT NULL"
        } else {
            subprograms = "p.OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION') AND p.PROCEDURE_NAME IS NULL"
        }
        return """
            SELECT NVL(p.PROCEDURE_NAME, p.OBJECT_NAME), p.SUBPROGRAM_ID, p.OVERLOAD,
                   a.POSITION, a.ARGUMENT_NAME, a.DATA_TYPE, a.IN_OUT, a.DEFAULTED,
                   a.TYPE_OWNER, a.TYPE_NAME, a.TYPE_SUBNAME, a.PLS_TYPE
            FROM SYS.ALL_PROCEDURES p
            LEFT JOIN SYS.ALL_ARGUMENTS a
              ON a.OBJECT_ID = p.OBJECT_ID AND a.SUBPROGRAM_ID = p.SUBPROGRAM_ID AND a.DATA_LEVEL = 0
            WHERE p.OWNER = \(owner) AND p.OBJECT_NAME = \(name) AND \(subprograms)
            ORDER BY p.SUBPROGRAM_ID, a.SEQUENCE
            """
    }

    public static func parseEntryPoints(rows: [[String?]], unit: OracleDebugUnit) -> [OracleDebugEntryPoint] {
        var order: [Int] = []
        var byID: [Int: (name: String, overload: String?, parameters: [OracleDebugParameter], result: OracleDebugParameter?)] = [:]
        for row in rows {
            func cell(_ index: Int) -> String? { row.count > index ? row[index] : nil }
            guard let name = cell(0), let subprogramID = cell(1).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
            else { continue }
            if byID[subprogramID] == nil {
                order.append(subprogramID)
                byID[subprogramID] = (name, cell(2), [], nil)
            }
            guard let dataType = cell(5), !dataType.isEmpty else { continue }
            let parameter = OracleDebugParameter(
                name: cell(4) ?? "",
                position: cell(3).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0,
                dataType: dataType,
                mode: OracleDebugParameter.Mode(inOut: cell(6)),
                hasDefault: cell(7)?.uppercased() == "Y",
                typeOwner: cell(8),
                typeName: cell(9),
                typeSubname: cell(10),
                plsType: cell(11)
            )
            if parameter.position == 0, cell(4) == nil {
                byID[subprogramID]?.result = parameter
            } else {
                byID[subprogramID]?.parameters.append(parameter)
            }
        }
        return order.compactMap { id in
            guard let entry = byID[id] else { return nil }
            return OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: unit.codeUnit, subprogram: entry.name, subprogramID: id),
                overload: entry.overload,
                parameters: entry.parameters,
                result: entry.result
            )
        }
    }

    public static func source(of unit: OracleDebugUnit) -> String {
        """
        SELECT LINE, TEXT
        FROM SYS.ALL_SOURCE
        WHERE OWNER = \(OracleDebugUnit.literal(unit.owner))
          AND NAME = \(OracleDebugUnit.literal(unit.name))
          AND TYPE = \(OracleDebugUnit.literal(unit.kind.rawValue))
        ORDER BY LINE
        """
    }

    // Lines stay where ALL_SOURCE numbers them, because both debug interfaces report those numbers.
    public static func assembleSource(rows: [(line: Int, text: String?)]) -> String {
        var lines: [String] = []
        for row in rows.sorted(by: { $0.line < $1.line }) where row.line >= 1 {
            while lines.count < row.line - 1 {
                lines.append("")
            }
            var text = row.text ?? ""
            // "\r\n" is one Character, so dropping the last Character removes either ending whole.
            if text.last?.isNewline == true {
                text.removeLast()
            }
            if lines.count == row.line - 1 {
                lines.append(text)
            } else {
                lines[row.line - 1] += text
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JDWP

    // Through EXECUTE IMMEDIATE of a CALL, so `SYS` resolves at SQL level and a package named SYS in the session's
    // schema cannot capture it (OracleServerOutput explains the measurement).
    public static let jdwpConnect = """
        BEGIN
          EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG_JDWP.CONNECT_TCP(:1, :2)' USING :1, :2;
        END;
        """

    // "4000-4999" or "4000": a range, as the DBA's ACE grants one. A list is refused rather than read as the range
    // between its first two ports, which would pick ports the ACE does not cover. SQL Developer's default is 4000-4999.
    public static func ports(from text: String) -> ClosedRange<UInt16>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { UInt16($0) }
        guard numbers.count == parts.count, let low = numbers.first, low > 0 else { return nil }
        let high = numbers.last ?? low
        guard high >= low else { return nil }
        return low...high
    }

    public static let defaultPorts = "4000-4999"

    // MARK: - Errors

    // Every ORA- code in a server message, in order; the first is the error, the rest its stack.
    public static func errorCodes(in message: String) -> [Int] {
        var codes: [Int] = []
        var remainder = Substring(message)
        while let range = remainder.range(of: "ORA-") {
            let digits = remainder[range.upperBound...].prefix { $0.isNumber }
            if let code = Int(digits) { codes.append(code) }
            remainder = remainder[range.upperBound...]
        }
        return codes
    }

    public static func jdwpFailure(fromMessage message: String) -> OracleJDWPFailure {
        let codes = errorCodes(in: message)
        let upper = message.uppercased()
        if codes.contains(24_247) { return .accessControlList }
        if codes.contains(1_031) { return .missingPrivilege }
        if codes.contains(30_683) || codes.contains(30_698) || codes.contains(30_681) || codes.contains(30_682) {
            return .unreachable(message)
        }
        // Autonomous AI Database lists the package as unavailable; the CALL then cannot resolve it.
        if upper.contains("DBMS_DEBUG_JDWP"), codes.contains(where: { [6_576, 904, 6_550, 4_067, 6_508, 942].contains($0) }) {
            return .packageUnavailable
        }
        if codes.contains(6_576) || codes.contains(904) { return .packageUnavailable }
        return .other(message)
    }

    // MARK: - Invocation

    public struct Invocation: Sendable, Equatable {
        public let block: String
        public let binds: [OracleBindValue]
    }

    public enum InvocationError: Error, Sendable, Equatable {
        // Text cannot become a value of this type; NULL or the default still can.
        case unsupportedArgument(name: String, typeName: String)
        // No local of this type can be declared, so not even NULL can be passed.
        case undeclarableArgument(name: String, typeName: String)
        case undeclarableResult(typeName: String)
    }

    // Runs the entry point and reports, through the payload: `S` or `F`, the error text, the number of outputs, each
    // output's name and value, then every DBMS_OUTPUT line. A failure is caught so the routine's output survives it;
    // the caller rolls back.
    public static func invocation(
        of entryPoint: OracleDebugEntryPoint,
        arguments: [String: OracleDebugArgumentValue],
        maxOutputLines: Int = 10_000
    ) throws -> Invocation {
        var declarations: [String] = []
        var prologue: [String] = []
        var callArguments: [String] = []
        var outputs: [(name: String, expression: String)] = []
        var binds: [OracleBindValue] = []

        func bind(_ value: String) -> String {
            binds.append(.text(value))
            return ":\(binds.count)"
        }

        for (index, parameter) in entryPoint.parameters.enumerated() {
            let value = arguments[parameter.name] ?? (parameter.hasDefault ? .defaultValue : .null)
            if parameter.mode == .input, value == .defaultValue, parameter.hasDefault {
                continue
            }
            // Every argument is a local of the parameter's own type, NULL included: Oracle picks an overload by the
            // types it is given, and a bare NULL or a text bind matches more than one.
            guard let declaration = parameter.declaration else {
                throw InvocationError.undeclarableArgument(name: parameter.name, typeName: parameter.displayType)
            }
            let local = "l_arg\(index + 1)"
            declarations.append("  \(local) \(declaration);")
            if parameter.mode != .output, case .text(let text) = value {
                guard let expression = parameter.inputExpression(bindReference: bind(text)) else {
                    throw InvocationError.unsupportedArgument(name: parameter.name, typeName: parameter.displayType)
                }
                prologue.append("  \(local) := \(expression);")
            }
            callArguments.append("\(OracleDebugUnit.quote(parameter.name)) => \(local)")
            if parameter.mode != .input, let text = parameter.textExpression(of: local) {
                outputs.append((parameter.name, text))
            }
        }

        var target = OracleDebugUnit.quote(entryPoint.entry.unit.owner)
        if entryPoint.entry.isPackaged {
            target += "." + OracleDebugUnit.quote(entryPoint.entry.unit.name)
        }
        target += "." + OracleDebugUnit.quote(entryPoint.entry.subprogram)
        let call = callArguments.isEmpty ? target : "\(target)(\(callArguments.joined(separator: ", ")))"

        var statement = "\(call);"
        if let result = entryPoint.result {
            guard let declaration = result.declaration else {
                throw InvocationError.undeclarableResult(typeName: result.displayType)
            }
            declarations.append("  l_result \(declaration);")
            statement = "l_result := \(call);"
            if let text = result.textExpression(of: "l_result") {
                outputs.insert((entryPoint.entry.subprogram, text), at: 0)
            }
        }

        let outputLines = outputs.map { "      put(\(OracleDebugUnit.literal($0.name)));\n      put(\($0.expression));" }
        let block = """
            DECLARE
              l_failed BOOLEAN := FALSE;
              l_error VARCHAR2(32767);
              l_line VARCHAR2(32767);
              l_status INTEGER;
              l_lines PLS_INTEGER := 0;
            \(declarations.joined(separator: "\n"))
            \(OracleDebugPayload.declarations)
            BEGIN
            \(prologue.joined(separator: "\n"))
              BEGIN
                \(statement)
              EXCEPTION
                WHEN OTHERS THEN
                  l_failed := TRUE;
                  l_error := SQLERRM;
              END;
              IF l_failed THEN
                put('F');
                put(l_error);
                put('0');
              ELSE
                put('S');
                put(NULL);
                put('\(outputs.count)');
            \(outputLines.joined(separator: "\n"))
              END IF;
              LOOP
                EXIT WHEN l_lines >= \(maxOutputLines);
                EXECUTE IMMEDIATE 'CALL SYS.DBMS_OUTPUT.GET_LINE(:1, :2)' USING OUT l_line, OUT l_status;
                EXIT WHEN l_status <> 0;
                put(l_line);
                l_lines := l_lines + 1;
              END LOOP;
            \(OracleDebugPayload.openCursor)
            END;
            """
        return Invocation(block: block, binds: binds)
    }

    public enum Ambiguity: Sendable, Equatable {
        // Leaving these parameters at their defaults leaves nothing to tell this overload from another.
        case needsValue([String])
        // The call matches another overload whatever values are given (PLS-00307).
        case unresolvable
    }

    // Oracle picks an overload by the named arguments it is given, so leaving out defaulted ones can leave two
    // overloads that both fit, and the call fails with PLS-00307 (`p(x NUMBER DEFAULT 1)` and
    // `p(x VARCHAR2 DEFAULT 'a')`, both started with the default). ALL_ARGUMENTS cannot give the default's value to
    // pass instead, so the person has to give one.
    public static func ambiguity(
        of entryPoint: OracleDebugEntryPoint,
        arguments: [String: OracleDebugArgumentValue],
        overloads: [OracleDebugEntryPoint]
    ) -> Ambiguity? {
        func value(of parameter: OracleDebugParameter) -> OracleDebugArgumentValue {
            arguments[parameter.name] ?? (parameter.hasDefault ? .defaultValue : .null)
        }
        let omitted = entryPoint.parameters.filter { $0.mode == .input && $0.hasDefault && value(of: $0) == .defaultValue }
        let passed = entryPoint.parameters.filter { parameter in !omitted.contains { $0.name == parameter.name } }
        for other in overloads where other.entry.unit == entryPoint.entry.unit
            && other.entry.subprogram == entryPoint.entry.subprogram
            && other.entry.subprogramID != entryPoint.entry.subprogramID
            && (other.result == nil) == (entryPoint.result == nil) {
            let takesEveryPassed = passed.allSatisfy { parameter in
                other.parameters.contains { $0.name == parameter.name && $0.declaration == parameter.declaration }
            }
            let needsNothingElse = other.parameters.allSatisfy { parameter in
                passed.contains { $0.name == parameter.name } || (parameter.mode == .input && parameter.hasDefault)
            }
            guard takesEveryPassed, needsNothingElse else { continue }
            let distinguishing = omitted.filter { parameter in
                !other.parameters.contains { $0.name == parameter.name && $0.declaration == parameter.declaration }
            }
            return distinguishing.isEmpty ? .unresolvable : .needsValue(distinguishing.map(\.name))
        }
        return nil
    }

    public struct InvocationReport: Sendable, Equatable {
        public let succeeded: Bool
        public let error: String?
        public let outputs: [(name: String, value: String?)]
        public let lines: [String]

        public static func == (lhs: InvocationReport, rhs: InvocationReport) -> Bool {
            lhs.succeeded == rhs.succeeded && lhs.error == rhs.error && lhs.lines == rhs.lines
                && lhs.outputs.map(\.name) == rhs.outputs.map(\.name)
                && lhs.outputs.map(\.value) == rhs.outputs.map(\.value)
        }
    }

    public static func invocationReport(fromPayload fields: [String?]) throws -> InvocationReport {
        var reader = OracleDebugPayloadReader(fields)
        let status = try reader.next()
        let error = try reader.next()
        let count = try reader.int() ?? 0
        var outputs: [(name: String, value: String?)] = []
        for _ in 0..<max(count, 0) {
            let name = try reader.next() ?? ""
            outputs.append((name, try reader.next()))
        }
        var lines: [String] = []
        while !reader.isAtEnd {
            lines.append(try reader.next() ?? "")
        }
        return InvocationReport(succeeded: status == "S", error: error, outputs: outputs, lines: lines)
    }
}

public enum OracleDebugArgumentValue: Sendable, Hashable {
    case text(String)
    case null
    case defaultValue
}

public struct OracleDebugEntryPoint: Sendable, Hashable {
    public let entry: OracleDebugEntry
    public let overload: String?
    public let parameters: [OracleDebugParameter]
    public let result: OracleDebugParameter?

    public init(entry: OracleDebugEntry, overload: String?, parameters: [OracleDebugParameter], result: OracleDebugParameter?) {
        self.entry = entry
        self.overload = overload
        self.parameters = parameters
        self.result = result
    }

    public var displayName: String {
        let list = parameters.map { "\($0.name) \($0.displayType)" }.joined(separator: ", ")
        var text = parameters.isEmpty ? entry.subprogram : "\(entry.subprogram)(\(list))"
        if let result {
            text += " RETURN \(result.displayType)"
        }
        return text
    }
}

public struct OracleDebugParameter: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case input
        case output
        case inputOutput

        init(inOut: String?) {
            switch inOut?.uppercased() {
            case "OUT": self = .output
            case "IN/OUT", "IN OUT": self = .inputOutput
            default: self = .input
            }
        }
    }

    public let name: String
    public let position: Int
    public let dataType: String
    public let mode: Mode
    public let hasDefault: Bool
    public let typeOwner: String?
    public let typeName: String?
    public let typeSubname: String?
    public let plsType: String?

    public init(
        name: String,
        position: Int,
        dataType: String,
        mode: Mode,
        hasDefault: Bool,
        typeOwner: String? = nil,
        typeName: String? = nil,
        typeSubname: String? = nil,
        plsType: String? = nil
    ) {
        self.name = name
        self.position = position
        self.dataType = dataType
        self.mode = mode
        self.hasDefault = hasDefault
        self.typeOwner = typeOwner
        self.typeName = typeName
        self.typeSubname = typeSubname
        self.plsType = plsType
    }

    private var qualifiedTypeName: String? {
        guard let typeName, !typeName.isEmpty else { return nil }
        return [typeOwner, typeName, typeSubname].compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }.joined(separator: ".")
    }

    public var displayType: String {
        if let plsType, !plsType.isEmpty { return plsType }
        if let qualified = qualifiedTypeName { return qualified }
        return dataType
    }

    enum Scalar {
        case text
        case nationalText
        case number
        case date
        case timestamp(String)
        case interval(String)
        case raw
        case characterLOB
        case binaryLOB
        case rowID
        case bfile
        case boolean
    }

    var scalar: Scalar? {
        let type = dataType.uppercased()
        switch type {
        case "VARCHAR2", "VARCHAR", "CHAR", "LONG", "STRING": return .text
        case "NVARCHAR2", "NCHAR": return .nationalText
        case "NUMBER", "FLOAT", "INTEGER", "BINARY_INTEGER", "PLS_INTEGER", "BINARY_FLOAT", "BINARY_DOUBLE",
             "PL/SQL PLS INTEGER", "PL/SQL BINARY INTEGER", "NATURAL", "NATURALN", "POSITIVE", "POSITIVEN", "SIMPLE_INTEGER":
            return .number
        case "DATE": return .date
        case "TIMESTAMP": return .timestamp("TIMESTAMP(9)")
        case "TIMESTAMP WITH TIME ZONE": return .timestamp("TIMESTAMP(9) WITH TIME ZONE")
        case "TIMESTAMP WITH LOCAL TIME ZONE": return .timestamp("TIMESTAMP(9) WITH LOCAL TIME ZONE")
        case "INTERVAL YEAR TO MONTH": return .interval("INTERVAL YEAR(9) TO MONTH")
        case "INTERVAL DAY TO SECOND": return .interval("INTERVAL DAY(9) TO SECOND(9)")
        case "RAW", "LONG RAW": return .raw
        case "CLOB": return .characterLOB
        case "NCLOB": return .characterLOB
        case "BLOB": return .binaryLOB
        case "ROWID", "UROWID": return .rowID
        case "BFILE": return .bfile
        case "PL/SQL BOOLEAN", "BOOLEAN": return .boolean
        default: return nil
        }
    }

    public var declaration: String? {
        if let scalar {
            switch scalar {
            case .text: return "VARCHAR2(32767)"
            case .nationalText: return "NVARCHAR2(16383)"
            case .number:
                return numberDeclaration
            case .date: return "DATE"
            case .timestamp(let declaration), .interval(let declaration): return declaration
            case .raw: return "RAW(32767)"
            case .characterLOB: return dataType.uppercased() == "NCLOB" ? "NCLOB" : "CLOB"
            case .binaryLOB: return "BLOB"
            case .rowID: return "UROWID"
            case .bfile: return "BFILE"
            case .boolean: return "BOOLEAN"
            }
        }
        if dataType.uppercased() == "REF CURSOR" { return "SYS_REFCURSOR" }
        guard let typeName, !typeName.isEmpty else { return nil }
        return [typeOwner, typeName, typeSubname].compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return OracleDebugUnit.quote(part)
        }.joined(separator: ".")
    }

    // An integer subtype with NOT NULL or a range cannot be declared bare; PLS_INTEGER holds every one of them.
    private var numberDeclaration: String {
        switch (plsType ?? dataType).uppercased() {
        case "BINARY_FLOAT": return "BINARY_FLOAT"
        case "BINARY_DOUBLE": return "BINARY_DOUBLE"
        case "PLS_INTEGER", "BINARY_INTEGER", "PL/SQL PLS INTEGER", "PL/SQL BINARY INTEGER", "NATURAL", "NATURALN",
             "POSITIVE", "POSITIVEN", "SIMPLE_INTEGER", "SIGNTYPE":
            return "PLS_INTEGER"
        default: return "NUMBER"
        }
    }

    // The text the person typed, converted explicitly to the parameter's type in the session's NLS formats.
    func inputExpression(bindReference: String) -> String? {
        guard let scalar else { return nil }
        switch scalar {
        case .text: return bindReference
        case .nationalText: return "TO_NCHAR(\(bindReference))"
        case .number:
            switch numberDeclaration {
            case "BINARY_FLOAT": return "TO_BINARY_FLOAT(\(bindReference))"
            case "BINARY_DOUBLE": return "TO_BINARY_DOUBLE(\(bindReference))"
            default: return "TO_NUMBER(\(bindReference))"
            }
        case .date: return "TO_DATE(\(bindReference))"
        case .timestamp(let declaration):
            return declaration.hasSuffix("WITH TIME ZONE") && !declaration.contains("LOCAL")
                ? "TO_TIMESTAMP_TZ(\(bindReference))"
                : "TO_TIMESTAMP(\(bindReference))"
        case .interval(let declaration):
            return declaration.hasPrefix("INTERVAL YEAR") ? "TO_YMINTERVAL(\(bindReference))" : "TO_DSINTERVAL(\(bindReference))"
        case .raw: return "HEXTORAW(\(bindReference))"
        case .characterLOB: return dataType.uppercased() == "NCLOB" ? "TO_NCLOB(\(bindReference))" : "TO_CLOB(\(bindReference))"
        case .binaryLOB: return nil
        case .rowID: return "CHARTOROWID(\(bindReference))"
        case .bfile: return nil
        case .boolean:
            return "CASE UPPER(TRIM(\(bindReference))) WHEN 'TRUE' THEN TRUE WHEN 'FALSE' THEN FALSE "
                + "WHEN '1' THEN TRUE WHEN '0' THEN FALSE END"
        }
    }

    func textExpression(of variable: String) -> String? {
        guard let scalar else { return nil }
        switch scalar {
        case .text, .nationalText: return "TO_CHAR(\(variable))"
        case .number, .date, .timestamp, .interval: return "TO_CHAR(\(variable))"
        case .raw: return "RAWTOHEX(\(variable))"
        case .characterLOB: return "TO_CHAR(SUBSTR(\(variable), 1, \(OracleDebugPayload.fieldLimit)))"
        case .binaryLOB: return nil
        case .rowID: return "ROWIDTOCHAR(\(variable))"
        case .bfile: return nil
        case .boolean: return "CASE WHEN \(variable) THEN 'TRUE' WHEN NOT \(variable) THEN 'FALSE' END"
        }
    }
}

// Which interface to try first, and what to do when JDWP cannot connect: Oracle SQL Developer's model, where the
// database connects back over JDWP and DBMS_DEBUG covers networks that block it.
public enum OracleDebugProtocolPreference: String, Sendable, CaseIterable {
    case automatic
    case jdwp
    case dbmsDebug

    public static let fieldID = "oracleDebugProtocol"
    public static let hostFieldID = "oracleDebuggerHost"
    public static let portsFieldID = "oracleDebuggerPorts"
}

public enum OracleDebugProtocolDecision: Sendable, Equatable {
    case jdwp
    case dbmsDebug(OracleDebugProbeReason)
    case fallBack
    case fail

    public static func initial(preference: OracleDebugProtocolPreference, host: String) -> OracleDebugProtocolDecision {
        switch preference {
        case .dbmsDebug:
            return .dbmsDebug(.chosen)
        case .jdwp:
            // Without a host CONNECT_TCP has nowhere to connect; say so before any session opens.
            return host.trimmingCharacters(in: .whitespaces).isEmpty ? .fail : .jdwp
        case .automatic:
            return host.trimmingCharacters(in: .whitespaces).isEmpty ? .dbmsDebug(.noDebuggerHost) : .jdwp
        }
    }

    // DBMS_DEBUG needs the same DEBUG CONNECT SESSION, so a privilege failure is final; so is anything unrecognized.
    public static func afterJDWPFailure(
        _ failure: OracleJDWPFailure,
        preference: OracleDebugProtocolPreference
    ) -> OracleDebugProtocolDecision {
        guard preference == .automatic else { return .fail }
        switch failure {
        case .accessControlList, .unreachable, .packageUnavailable, .timedOut, .noFreePort, .handshakeFailed, .unexpectedPeer:
            return .fallBack
        case .missingPrivilege, .noDebuggerHost, .other:
            return .fail
        }
    }
}
