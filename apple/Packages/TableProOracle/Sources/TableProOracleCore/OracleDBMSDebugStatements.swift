import Foundation

// DBMS_DEBUG's two sessions: the target runs the routine, the supervisor drives it. Every supervisor call is one
// block that answers through `OracleDebugPayload`, because the runtime_info and program_info records cannot be bound.
public enum OracleDBMSDebugStatements {
    // DBMS_DEBUG's break flags.
    public enum BreakFlags {
        public static let breakpointsOnly = 0
        public static let nextLine = 32
        public static let anyCall = 12
        // Named backwards in the package (its own comment says so): this one stops in the caller after the return.
        public static let anyReturn = 512
        public static let abortExecution = 8_192
    }

    public enum Status {
        public static let success = 0
        public static let noSuchObject = 3
        public static let illegalLine = 12
        public static let badHandle = 16
        public static let indexedTable = 18
        public static let timeout = 31
        public static let nullValue = 32
        public static let nullCollection = 40
    }

    public enum Reason {
        public static let interpreterStarting = 2
        public static let breakpoint = 3
        public static let knlExit = 25
    }

    // How long the target waits for the supervisor at a stop before it aborts itself. The supervisor pings it while
    // the person reads a pause, so only a supervisor that went away lets it run out (measured: ORA-06543 after the
    // timeout, its work rolled back).
    public static let targetTimeoutSeconds = 30
    public static let pingIntervalSeconds = 10
    // How long one supervisor wait lasts before it returns to check for Stop and for the target's call ending.
    // Also the longest Stop's kill waits on the gate behind a poll, inside its 3 second budget.
    public static let supervisorTimeoutSeconds = 1

    static let abortOnTimeout = 3
    static let infoFlags = 2 + 4 + 8

    // MARK: - Target

    public static func targetSetup(debugID: String) -> (block: String, binds: [OracleBindValue]) {
        let block = """
            DECLARE
              l_id VARCHAR2(32767);
              l_timeout BINARY_INTEGER;
            BEGIN
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.INITIALIZE(:1) INTO :2' USING :1, OUT l_id;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.SET_TIMEOUT_BEHAVIOUR(\(abortOnTimeout))';
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.SET_TIMEOUT(\(targetTimeoutSeconds)) INTO :1' USING OUT l_timeout;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DEBUG.DEBUG_ON()';
            END;
            """
        return (block, [.text(debugID)])
    }

    // Read before DEBUG_ON, so the target's own PL/SQL does not stop it. DBMS_DEBUG_JDWP's functions answer for any
    // user (EXECUTE is granted to PUBLIC, measured); V$SESSION needs SELECT_CATALOG_ROLE; the SID alone always works.
    public static let sessionIdentityQueries = [
        """
        SELECT SYS.DBMS_DEBUG_JDWP.CURRENT_SESSION_ID, SYS.DBMS_DEBUG_JDWP.CURRENT_SESSION_SERIAL, \
        SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.DUAL
        """,
        "SELECT SID, SERIAL#, SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.V_$SESSION WHERE SID = SYS_CONTEXT('USERENV', 'SID')",
        "SELECT SYS_CONTEXT('USERENV', 'SID'), NULL, SYS_CONTEXT('USERENV', 'INSTANCE') FROM SYS.DUAL"
    ]

    public static func sessionIdentity(fromRow row: [String?]) -> OracleDebugSessionIdentity? {
        func number(_ index: Int) -> Int? {
            (row.count > index ? row[index] : nil).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard let sid = number(0) else { return nil }
        return OracleDebugSessionIdentity(sid: sid, serial: number(1), instance: number(2))
    }

    // Ends a target the supervisor cannot reach between breakpoints. Needs ALTER SYSTEM; ORA-01031 otherwise.
    public static func killSession(_ identity: OracleDebugSessionIdentity) -> String? {
        guard let serial = identity.serial else { return nil }
        let instance = identity.instance.map { ",@\($0)" } ?? ""
        return "ALTER SYSTEM KILL SESSION '\(identity.sid),\(serial)\(instance)' IMMEDIATE"
    }

    // MARK: - Supervisor

    // The supervisor runs no code of the person's, so its schema can be its own, which keeps `SYS` meaning the schema
    // in the blocks below.
    public static let ownSchema = """
        BEGIN
          EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA = "' || REPLACE(SYS_CONTEXT('USERENV', 'SESSION_USER'), '"', '""') || '"';
        END;
        """

    public static func attach(debugID: String) -> (block: String, binds: [OracleBindValue]) {
        let block = """
            DECLARE
              l_timeout BINARY_INTEGER;
            BEGIN
              l_timeout := SYS.DBMS_DEBUG.SET_TIMEOUT(\(supervisorTimeoutSeconds));
              SYS.DBMS_DEBUG.ATTACH_SESSION(:1);
            END;
            """
        return (block, [.text(debugID)])
    }

    public static let detach = """
        BEGIN
          SYS.DBMS_DEBUG.DETACH_SESSION;
        END;
        """

    public static let ping = """
        BEGIN
          SYS.DBMS_DEBUG.PING;
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
        """

    // `flags` nil synchronizes instead of continuing. A stop answers the runtime record and the backtrace in one round
    // trip; a terminated program has no backtrace, and asking for one there raises inside SYS.PBREAK (measured).
    public static func resume(flags: Int?) -> String {
        let call = flags.map { "SYS.DBMS_DEBUG.CONTINUE(l_info, \($0), \(infoFlags))" }
            ?? "SYS.DBMS_DEBUG.SYNCHRONIZE(l_info, \(infoFlags))"
        return """
            DECLARE
              l_info SYS.DBMS_DEBUG.RUNTIME_INFO;
              l_trace SYS.DBMS_DEBUG.BACKTRACE_TABLE;
              l_status BINARY_INTEGER;
            \(OracleDebugPayload.declarations)
            BEGIN
              l_status := \(call);
              put(TO_CHAR(l_status));
              put(TO_CHAR(l_info.Reason));
              put(TO_CHAR(l_info.Terminated));
              put(TO_CHAR(l_info.Line#));
              put(TO_CHAR(l_info.Breakpoint));
              IF l_status = 0 AND NVL(l_info.Terminated, 0) = 0 THEN
                SYS.DBMS_DEBUG.PRINT_BACKTRACE(l_trace);
                put(TO_CHAR(l_trace.COUNT));
                FOR i IN 1 .. l_trace.COUNT LOOP
                  put(l_trace(i).Owner);
                  put(l_trace(i).Name);
                  put(TO_CHAR(l_trace(i).Namespace));
                  put(TO_CHAR(l_trace(i).LibunitType));
                  put(TO_CHAR(l_trace(i).Line#));
                  put(l_trace(i).EntrypointName);
                END LOOP;
              ELSE
                put('0');
              END IF;
            \(OracleDebugPayload.openCursor)
            END;
            """
    }

    public static func setBreakpoint(unit: OracleDebugUnit, line: Int) -> String {
        """
        DECLARE
          l_program SYS.DBMS_DEBUG.PROGRAM_INFO;
          l_number BINARY_INTEGER;
          l_status BINARY_INTEGER;
        \(OracleDebugPayload.declarations)
        BEGIN
          l_program.Namespace := \(unit.kind.namespace);
          l_program.Owner := \(OracleDebugUnit.literal(unit.owner));
          l_program.Name := \(OracleDebugUnit.literal(unit.name));
          l_program.Line# := \(line);
          l_status := SYS.DBMS_DEBUG.SET_BREAKPOINT(l_program, \(line), l_number);
          put(TO_CHAR(l_status));
          put(TO_CHAR(l_number));
        \(OracleDebugPayload.openCursor)
        END;
        """
    }

    public static func deleteBreakpoints(_ numbers: [Int]) -> String {
        let calls = numbers.map { "  l_status := SYS.DBMS_DEBUG.DELETE_BREAKPOINT(\($0));" }.joined(separator: "\n")
        return """
            DECLARE
              l_status BINARY_INTEGER;
            BEGIN
            \(calls.isEmpty ? "  NULL;" : calls)
            END;
            """
    }

    // GET_LINE_MAP answers from any session, before or without ATTACH_SESSION (measured), so it also places JDWP
    // breakpoints in a unit that has not loaded yet.
    public static func lineMap(of unit: OracleDebugUnit) -> String {
        """
        DECLARE
          l_program SYS.DBMS_DEBUG.PROGRAM_INFO;
          l_max BINARY_INTEGER;
          l_entries BINARY_INTEGER;
          l_map RAW(32767);
          l_status BINARY_INTEGER;
        \(OracleDebugPayload.declarations)
        BEGIN
          l_program.Namespace := \(unit.kind.namespace);
          l_program.Owner := \(OracleDebugUnit.literal(unit.owner));
          l_program.Name := \(OracleDebugUnit.literal(unit.name));
          l_status := SYS.DBMS_DEBUG.GET_LINE_MAP(l_program, l_max, l_entries, l_map);
          put(TO_CHAR(l_status));
          put(TO_CHAR(l_max));
          put(RAWTOHEX(l_map));
        \(OracleDebugPayload.openCursor)
        END;
        """
    }

    public struct ValueRequest: Sendable, Equatable {
        public let name: String
        // Nil reads a package variable through its handle; otherwise DBMS_DEBUG's frame number.
        public let frame: Int?
        public let package: OracleDebugUnit?

        public init(name: String, frame: Int) {
            self.name = name
            self.frame = frame
            self.package = nil
        }

        public init(name: String, package: OracleDebugUnit) {
            self.name = name
            self.frame = nil
            self.package = package
        }
    }

    // A name comes from the unit's source text, so request n's goes in as bind :n, never as SQL.
    public static func values(_ requests: [ValueRequest]) -> (block: String, binds: [OracleBindValue]) {
        let reads = requests.enumerated().map { index, request -> String in
            let name = ":\(index + 1)"
            if let package = request.package {
                return """
                      l_handle.Namespace := \(package.kind.namespace);
                      l_handle.Owner := \(OracleDebugUnit.literal(package.owner));
                      l_handle.Name := \(OracleDebugUnit.literal(package.name));
                      l_value := NULL;
                      l_status := SYS.DBMS_DEBUG.GET_VALUE(\(name), l_handle, l_value, NULL);
                      put(TO_CHAR(l_status));
                      put(l_value);
                    """
            }
            return """
                  l_value := NULL;
                  l_status := SYS.DBMS_DEBUG.GET_VALUE(\(name), \(request.frame ?? 0), l_value, NULL);
                  put(TO_CHAR(l_status));
                  put(l_value);
                """
        }
        let block = """
            DECLARE
              l_handle SYS.DBMS_DEBUG.PROGRAM_INFO;
              l_value VARCHAR2(32767);
              l_status BINARY_INTEGER;
            \(OracleDebugPayload.declarations)
            BEGIN
            \(reads.joined(separator: "\n"))
            \(OracleDebugPayload.openCursor)
            END;
            """
        return (block, requests.map { .text($0.name) })
    }

    // MARK: - Answers

    public struct Frame: Sendable, Equatable {
        public let owner: String?
        public let name: String?
        public let namespace: Int?
        public let libunitType: Int?
        public let line: Int?
        public let entryPoint: String?

        public init(owner: String?, name: String?, namespace: Int?, libunitType: Int?, line: Int?, entryPoint: String?) {
            self.owner = owner
            self.name = name
            self.namespace = namespace
            self.libunitType = libunitType
            self.line = line
            self.entryPoint = entryPoint
        }

        // The anonymous block that called the entry point has namespace 0 and no name.
        public var unit: OracleDebugUnit? {
            guard let owner, let name, !name.isEmpty, let namespace,
                  let kind = OracleDebugUnitKind(namespace: namespace, libunitType: libunitType ?? -1)
            else { return nil }
            return OracleDebugUnit(owner: owner, name: name, kind: kind)
        }
    }

    public struct Event: Sendable, Equatable {
        public let status: Int
        public let reason: Int?
        public let terminated: Bool
        public let line: Int?
        public let breakpoint: Int?
        // Oldest first, as PRINT_BACKTRACE numbers them: GET_VALUE's frame number is this index plus one.
        public let backtrace: [Frame]

        public var timedOut: Bool { status == Status.timeout }
        public var isPause: Bool { status == Status.success && !terminated }
    }

    public static func event(fromPayload fields: [String?]) throws -> Event {
        var reader = OracleDebugPayloadReader(fields)
        let status = try reader.int() ?? -1
        let reason = try reader.int()
        let terminated = (try reader.int() ?? 0) != 0
        let line = try reader.int()
        let breakpoint = try reader.int()
        let count = try reader.int() ?? 0
        var frames: [Frame] = []
        for _ in 0..<max(count, 0) {
            frames.append(Frame(
                owner: try reader.next(),
                name: try reader.next(),
                namespace: try reader.int(),
                libunitType: try reader.int(),
                line: try reader.int(),
                entryPoint: try reader.next()
            ))
        }
        return Event(status: status, reason: reason, terminated: terminated, line: line, breakpoint: breakpoint, backtrace: frames)
    }

    public static func breakpointAnswer(fromPayload fields: [String?]) throws -> (status: Int, number: Int?) {
        var reader = OracleDebugPayloadReader(fields)
        return (try reader.int() ?? -1, try reader.int())
    }

    public static func valueAnswers(fromPayload fields: [String?], count: Int) throws -> [(status: Int, value: String?)] {
        var reader = OracleDebugPayloadReader(fields)
        var answers: [(status: Int, value: String?)] = []
        for _ in 0..<count {
            answers.append((try reader.int() ?? -1, try reader.next()))
        }
        return answers
    }

    public static func value(status: Int, text: String?) -> OracleDebugValue? {
        switch status {
        case Status.success: return .scalar(text)
        case Status.nullValue, Status.nullCollection: return .scalar(nil)
        case Status.indexedTable: return .collection(count: nil)
        default: return nil
        }
    }

    // Line N is executable when bit N mod 8 of byte N / 8 is set (the package's own description).
    public static func executableLines(fromPayload fields: [String?]) throws -> [Int]? {
        var reader = OracleDebugPayloadReader(fields)
        guard try reader.int() == Status.success else { return nil }
        let maxLine = try reader.int() ?? 0
        let hex = try reader.next() ?? ""
        return executableLines(hexMap: hex, maxLine: maxLine)
    }

    public static func executableLines(hexMap hex: String, maxLine: Int) -> [Int] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        // The map holds eight lines a byte, so a larger `maxLine` adds nothing to read.
        let last = min(max(maxLine, 0), bytes.count * 8 - 1)
        guard last >= 1 else { return [] }
        var lines: [Int] = []
        for line in 1...last where bytes[line / 8] & (1 << UInt8(line % 8)) != 0 {
            lines.append(line)
        }
        return lines
    }
}
