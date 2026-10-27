#!/usr/bin/env bash
#
# Debug PL/SQL against a real Oracle server through both of the Oracle plugin's mechanisms: DBMS_DEBUG_JDWP, where the
# database connects back to this Mac, and DBMS_DEBUG, two client sessions. Runs TableProOracleCore's engine as the
# plugin does: the first stop, breakpoints moving to the next line with code, stepping, step out, the stack, variables
# (package, record, collection, quoted names), function results, overloads that differ only in a parameter's type,
# the refusal of a call two overloads both match once defaults are left out, a unit loaded before the debugger
# attached, Stop while paused, while reads and breakpoint calls run, while running and inside a call that never returns
# to PL/SQL, and what Stop answers when it cannot end the target, the fallback from JDWP when the ACL refuses it, the
# database never connects or the connection comes from an address that is not the database's, a start the caller
# cancels, and the privilege refusal.
#
# Usage:
#   scripts/probes/check-oracle-debugger.sh [container] [host] [port] [debugger host]
#
# Defaults suit a throwaway Oracle Free container on Docker Desktop, which the database reaches this Mac through as
# host.docker.internal:
#   docker run -d --name oracle-debug-probe -p 127.0.0.1:1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# Setup runs as SYS inside the container: DEBUG CONNECT SESSION for PROBE, users NOACL (no ACE) and NODEBUG (no
# DEBUG CONNECT SESSION), jdwp ACEs for the debugger host and for 10.255.255.1 (which drops packets, for the timeout),
# and PROBE's units PKG_CALC, PKG_OVER, PKG_AMBIG, P_WRITE, F_CALC, P_SPIN and P_BLOCKED compiled at
# PLSQL_OPTIMIZE_LEVEL 1.
# ALTER SYSTEM is granted to PROBE only for the scenarios that kill a target, then revoked. The listener uses ports
# 15400-15420; macOS may ask once whether the probe may accept incoming connections. Exits non-zero on a
# disagreement, 3 when a prerequisite is missing.

set -uo pipefail

CONTAINER="${1:-oracle-debug-probe}"
HOST="${2:-127.0.0.1}"
PORT="${3:-1521}"
DEBUGGER_HOST="${4:-host.docker.internal}"
UNREACHABLE_HOST="10.255.255.1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
command -v swift > /dev/null || {
    echo "swift not found" >&2
    exit 3
}
docker exec "$CONTAINER" true 2> /dev/null || {
    echo "container $CONTAINER is not running" >&2
    exit 3
}

sql() {
    docker exec -i "$CONTAINER" bash -lc "sqlplus -S -L '$1'" > /dev/null
}

sql "sys/probe_pw@localhost:1521/FREEPDB1 as sysdba" <<SQL
whenever sqlerror continue
grant debug connect session, create procedure to probe;
create user noacl identified by probe_pw;
grant create session, debug connect session to noacl;
create user nodebug identified by probe_pw;
grant create session to nodebug;
begin
  for h in (select '$DEBUGGER_HOST' host from dual union all select '$UNREACHABLE_HOST' from dual) loop
    begin
      dbms_network_acl_admin.append_host_ace(host => h.host, lower_port => 15400, upper_port => 15420,
        ace => xs\$ace_type(privilege_list => xs\$name_list('jdwp'), principal_name => 'PROBE',
                            principal_type => xs_acl.ptype_db));
    exception
      -- An ACE an earlier run left for an overlapping range already covers it.
      when others then null;
    end;
  end loop;
end;
/
exit
SQL

sql "probe/probe_pw@localhost:1521/FREEPDB1" <<'SQL'
whenever sqlerror continue
create table probe_log (id number generated always as identity, note varchar2(100));
create or replace package pkg_calc as
  g_spec_count pls_integer := 0;
  function add_tax(p_amount number) return number;
  function add_tax(p_amount number, p_rate number) return number;
  procedure run(p_n pls_integer);
end pkg_calc;
/
create or replace package body pkg_calc as
  g_rate number := 0.1; "g.Rate" number := 0.2;
  function add_tax(p_amount number) return number is
    l_tax number;
  begin
    l_tax := p_amount * g_rate;
    return p_amount + l_tax;
  end add_tax;
  procedure run(p_n pls_integer) is
    l_total number := 0;
    l_name  varchar2(30) := 'probe'; "a.b" number := 7; "Mixed case" varchar2(10) := 'mc';
  begin
    for i in 1 .. p_n loop
      l_total := l_total + add_tax(i);
    end loop;
    dbms_output.put_line(l_name || ' total=' || l_total);
  end run;
  function add_tax(p_amount number, p_rate number) return number is
  begin
    return p_amount + p_amount * p_rate;
  end add_tax;
end pkg_calc;
/
create or replace procedure p_write(p_note varchar2, p_count out number) is
  l_i pls_integer := 0;
begin
  insert into probe_log(note) values (p_note);
  l_i := l_i + 1;
  select count(*) into p_count from probe_log;
  dbms_output.put_line('wrote ' || p_note);
end p_write;
/
create or replace function f_calc(p_a number, p_b varchar2 default 'x', p_flag boolean default true) return number is
  type t_nums is table of number index by pls_integer;
  type t_rec is record (a number, b varchar2(10));
  l_nums t_nums;
  l_rec t_rec;
  l_ok boolean := p_flag;
  l_when date := date '2024-01-02';
begin
  l_nums(1) := p_a;
  l_rec.a := p_a;
  l_rec.b := p_b;
  return p_a * 2;
end f_calc;
/
create or replace procedure p_spin(p_seconds number) is
  l_end timestamp with time zone := systimestamp + numtodsinterval(p_seconds, 'SECOND');
  l_n pls_integer := 0;
begin
  insert into probe_log(note) values ('spin start');
  while systimestamp < l_end loop
    l_n := l_n + 1;
  end loop;
  dbms_output.put_line('spun ' || l_n);
end p_spin;
/
create or replace package pkg_over as
  procedure show(p_x number);
  procedure show(p_x varchar2);
end pkg_over;
/
create or replace package body pkg_over as
  procedure show(p_x number) is
  begin
    dbms_output.put_line('number ' || nvl(to_char(p_x), 'null'));
  end show;
  procedure show(p_x varchar2) is
  begin
    dbms_output.put_line('varchar2 ' || nvl(p_x, 'null'));
  end show;
end pkg_over;
/
create or replace package pkg_ambig as
  procedure p(x number default 1);
  procedure p(x varchar2 default 'a');
  procedure q(a number);
  procedure q(a number, b varchar2 default 'x');
end pkg_ambig;
/
create or replace package body pkg_ambig as
  procedure p(x number default 1) is
  begin
    dbms_output.put_line('number ' || x);
  end p;
  procedure p(x varchar2 default 'a') is
  begin
    dbms_output.put_line('varchar2 ' || x);
  end p;
  procedure q(a number) is
  begin
    dbms_output.put_line('q1 ' || a);
  end q;
  procedure q(a number, b varchar2 default 'x') is
  begin
    dbms_output.put_line('q2 ' || a || ' ' || b);
  end q;
end pkg_ambig;
/
create or replace procedure p_blocked is
  l_n number;
begin
  insert into probe_log(note) values ('blocked');
  dbms_session.sleep(30);
  dbms_output.put_line('slept');
end p_blocked;
/
alter procedure p_blocked compile plsql_optimize_level=1 reuse settings;
alter package pkg_over compile body plsql_optimize_level=1 reuse settings;
alter package pkg_ambig compile body plsql_optimize_level=1 reuse settings;
alter package pkg_calc compile plsql_optimize_level=1 reuse settings;
alter package pkg_calc compile body plsql_optimize_level=1 reuse settings;
alter procedure p_write compile plsql_optimize_level=1 reuse settings;
alter function f_calc compile plsql_optimize_level=1 reuse settings;
alter procedure p_spin compile plsql_optimize_level=1 reuse settings;
grant execute, debug on f_calc to noacl;
delete from probe_log;
commit;
exit
SQL

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProOracle")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProOracleCore", package: "TableProOracle")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProOracleCore

let args = CommandLine.arguments
let host = args[1]
let port = Int(args[2]) ?? 1_521
let debuggerHost = args[3]
let unreachableHost = args[4]
let scenario = args.count > 5 ? args[5] : "all"
nonisolated(unsafe) var failures = 0

func log(_ text: String) {
    let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    print("[\(stamp)] \(text)")
    fflush(stdout)
}

func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

func open(_ user: String) async throws -> OracleCoreConnection {
    let connection = OracleCoreConnection(options: OracleConnectionOptions(
        host: host, port: port, user: user, password: "probe_pw", identifierMode: .service, serviceName: "FREEPDB1"
    ))
    try await connection.connect()
    try await connection.captureServerOutput()
    return connection
}

func scalar(_ sql: String, as user: String = "probe") async -> String? {
    guard let connection = try? await open(user) else { return nil }
    defer { connection.disconnect() }
    return try? await connection.executeQuery(sql).rows.first?.first?.stringValue
}

func entryPoints(_ unit: OracleDebugUnit, as user: String = "probe") async throws -> [OracleDebugEntryPoint] {
    let connection = try await open(user)
    defer { connection.disconnect() }
    let result = try await connection.executeQuery(OracleDebugStatements.entryPoints(of: unit))
    return OracleDebugStatements.parseEntryPoints(rows: result.rows.map { $0.map(\.stringValue) }, unit: unit)
}

final class Opened: @unchecked Sendable {
    var connections: [OracleCoreConnection] = []
    let lock = NSLock()
    func add(_ c: OracleCoreConnection) { lock.withLock { connections.append(c) } }
    func closeAll() { lock.withLock { connections.forEach { $0.disconnect() }; connections.removeAll() } }
}

func launch(
    _ entry: OracleDebugEntryPoint,
    arguments: [String: OracleDebugArgumentValue],
    breakpoints: [OracleDebugBreakpointRequest] = [],
    preference: OracleDebugProtocolPreference,
    debuggerHost: String = debuggerHost,
    user: String = "probe",
    timeout: Duration = .seconds(15),
    databaseHost: String = host,
    startup: String? = nil,
    overloads: [OracleDebugEntryPoint] = [],
    opened: Opened
) async throws -> any OracleDebugEngine {
    try await OracleDebugLauncher.launch(
        OracleDebugLaunch(
            entryPoint: entry,
            arguments: arguments,
            breakpoints: breakpoints,
            preference: preference,
            debuggerHost: debuggerHost,
            ports: 15_400...15_420,
            databaseHost: databaseHost,
            databasePort: port,
            overloads: overloads,
            connectTimeout: timeout
        ),
        openSession: {
            let c = try await open(user)
            opened.add(c)
            if let startup { _ = try await c.executeQuery(startup) }
            return c
        }
    )
}

func drain(_ engine: any OracleDebugEngine) -> Task<[OracleDebugNotice], Never> {
    let stream = engine.notices
    return Task {
        var all: [OracleDebugNotice] = []
        for await notice in stream { all.append(notice) }
        return all
    }
}

func describe(_ stop: OracleDebugStop) -> String {
    switch stop {
    case .paused(let location): return "paused \(location.unit.kind.rawValue) \(location.unit.name) line \(location.line)"
    case .finished(let outcome): return "finished " + outcome.values.map { "\($0.name)=\($0.value ?? "NULL")" }.joined(separator: ", ")
    case .failed(let failure): return "failed \(failure)"
    }
}

func describe(_ variables: [OracleDebugVariable]) -> String {
    variables.map { variable in
        let value: String
        switch variable.value {
        case .scalar(let text): value = text ?? "NULL"
        case .record(let members): value = "(" + members.map { "\($0.name) => \($0.value ?? "NULL")" }.joined(separator: ", ") + ")"
        case .collection(let count): value = "[collection \(count.map(String.init) ?? "?")]"
        case .unavailable: value = "?"
        }
        return "\(variable.kind) \(variable.name) \(variable.typeName ?? "") = \(value)"
    }.joined(separator: "; ")
}

let calcBody = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
let pWrite = OracleDebugUnit(owner: "PROBE", name: "P_WRITE", kind: .procedure)
let fCalc = OracleDebugUnit(owner: "PROBE", name: "F_CALC", kind: .function)
let pSpin = OracleDebugUnit(owner: "PROBE", name: "P_SPIN", kind: .procedure)
let overBody = OracleDebugUnit(owner: "PROBE", name: "PKG_OVER", kind: .packageBody)
let pBlocked = OracleDebugUnit(owner: "PROBE", name: "P_BLOCKED", kind: .procedure)
let ambigBody = OracleDebugUnit(owner: "PROBE", name: "PKG_AMBIG", kind: .packageBody)

func output(_ notices: Task<[OracleDebugNotice], Never>) async -> [String] {
    await notices.value.compactMap { notice -> String? in
        if case .serverOutput(let line) = notice { return line }
        return nil
    }
}

func walkthrough(_ preference: OracleDebugProtocolPreference) async throws {
    log("=== walkthrough \(preference)")
    let entries = try await entryPoints(calcBody)
    log("entry points: " + entries.map { "\($0.entry.identity) \($0.displayName)" }.joined(separator: " | "))
    guard let run = entries.first(where: { $0.entry.subprogram == "RUN" }) else { check(false, "RUN listed"); return }
    let opened = Opened()
    defer { opened.closeAll() }
    let engine = try await launch(run, arguments: ["P_N": .text("2")], breakpoints: [.init(unit: calcBody, line: 4)], preference: preference, opened: opened)
    let notices = drain(engine)
    log("mechanism \(engine.mechanism)")
    let first = try await engine.firstStop()
    log("firstStop: \(describe(first))")
    check(first == .paused(OracleDebugLocation(unit: calcBody, line: 9)), "\(preference): first stop is RUN's header line 9")
    log("stack: \(try await engine.stack().map { "\($0.level):\($0.location.unit.name):\($0.location.line):\($0.subprogram ?? "")" })")
    log("vars: \(describe(try await engine.variables(inFrame: 0)))")
    let placed = try await engine.setBreakpoint(in: calcBody, line: 6)
    check(placed == 6, "\(preference): breakpoint at 6 placed at \(placed.map(String.init) ?? "nil")")
    let moved = try await engine.setBreakpoint(in: calcBody, line: 4)
    log("breakpoint at 4 placed at \(moved.map(String.init) ?? "nil")")
    if let moved { try await engine.removeBreakpoint(in: calcBody, line: moved) }
    let held = try await engine.perform(.continueExecution)
    log("continue with the start breakpoint still set: \(describe(held))")
    check(held == .paused(OracleDebugLocation(unit: calcBody, line: 5)), "\(preference): the start breakpoint asked for 4 still stops at 5")
    // A start breakpoint comes off by the line the host asked for, wherever it landed.
    try await engine.removeBreakpoint(in: calcBody, line: 4)
    let atBreakpoint = try await engine.perform(.continueExecution)
    log("continue: \(describe(atBreakpoint))")
    check(atBreakpoint == .paused(OracleDebugLocation(unit: calcBody, line: 6)), "\(preference): continue stops at 6")
    let stack = try await engine.stack()
    log("stack: \(stack.map { "\($0.level):\($0.location.unit.name):\($0.location.line):\($0.subprogram ?? "")" })")
    check(stack.count == 2 && stack.last?.location.line == 14, "\(preference): two frames, caller at line 14")
    let top = try await engine.variables(inFrame: 0)
    log("vars 0: \(describe(top))")
    check(top.contains { $0.name == "P_AMOUNT" && $0.value == .scalar("1") }, "\(preference): P_AMOUNT = 1")
    check(top.contains { $0.name == "G_RATE" && $0.kind == .package && $0.value == .scalar(".1") }, "\(preference): G_RATE = .1 as package variable")
    let caller = try await engine.variables(inFrame: 1)
    log("vars 1: \(describe(caller))")
    check(caller.contains { $0.name == "L_NAME" && $0.value == .scalar("probe") }, "\(preference): caller L_NAME = probe")
    if engine.mechanism == .dbmsDebug {
        // Asked for unquoted, GET_VALUE reads "a.b" as member b of a. Quoted, it finds "a.b" and "g.Rate", but never a
        // name with a space.
        check(caller.contains { $0.name == "a.b" && $0.value == .scalar("7") }, "dbmsDebug: caller \"a.b\" = 7")
        check(caller.contains { $0.name == "Mixed case" && $0.value == .unavailable }, "dbmsDebug: caller \"Mixed case\" shows as not readable")
        check(top.contains { $0.name == "g.Rate" && $0.kind == .package && $0.value == .scalar(".2") }, "dbmsDebug: \"g.Rate\" = .2 as package variable")
    }
    let over = try await engine.perform(.stepOver)
    log("step over: \(describe(over))")
    check(over == .paused(OracleDebugLocation(unit: calcBody, line: 7)), "\(preference): step over reaches 7")
    let out = try await engine.perform(.stepOut)
    log("step out: \(describe(out))")
    if case .paused(let location) = out { check(location.line == 13 || location.line == 14, "\(preference): step out lands in RUN (line \(location.line))") } else { check(false, "step out paused") }
    let into = try await engine.perform(.stepOver)
    log("step over: \(describe(into))")
    try await engine.removeBreakpoint(in: calcBody, line: 6)
    let end = try await engine.perform(.continueExecution)
    log("continue to end: \(describe(end))")
    if case .finished = end { check(true, "\(preference): finished") } else { check(false, "\(preference): finished") }
    let all = await notices.value
    log("notices: \(all)")
    check(all.contains(.serverOutput("probe total=3.3")), "\(preference): DBMS_OUTPUT line delivered")
    check(await engine.stop() == .ended, "\(preference): Stop after the routine finished answers ended")
}

func outputs(_ preference: OracleDebugProtocolPreference) async throws {
    log("=== outputs \(preference)")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(fCalc).first else { check(false, "F_CALC entry"); return }
    log("F_CALC entry \(entry.displayName) params \(entry.parameters.map { "\($0.name) \($0.mode) default=\($0.hasDefault)" })")
    let engine = try await launch(entry, arguments: ["P_A": .text("21"), "P_B": .defaultValue, "P_FLAG": .text("false")], breakpoints: [.init(unit: fCalc, line: 12)], preference: preference, opened: opened)
    let notices = drain(engine)
    log("first: \(describe(try await engine.firstStop()))")
    let stop = try await engine.perform(.continueExecution)
    log("at 12: \(describe(stop))")
    log("vars: \(describe(try await engine.variables(inFrame: 0)))")
    let end = try await engine.perform(.continueExecution)
    log("end: \(describe(end))")
    check(end == .finished(OracleDebugOutcome(values: [.init(name: "F_CALC", typeName: "NUMBER", value: "42")])), "\(preference): F_CALC returns 42")
    _ = await notices.value
    check(await engine.stop() == .ended, "\(preference): Stop after F_CALC finished answers ended")
}

func stopPaused(_ preference: OracleDebugProtocolPreference) async throws {
    log("=== stop while paused \(preference)")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(pWrite).first else { return }
    let note = "stop-paused-\(preference.rawValue)"
    let engine = try await launch(entry, arguments: ["P_NOTE": .text(note)], breakpoints: [.init(unit: pWrite, line: 6)], preference: preference, opened: opened)
    _ = drain(engine)
    log("first: \(describe(try await engine.firstStop()))")
    let at = try await engine.perform(.continueExecution)
    log("after insert: \(describe(at))")
    let started = Date()
    let outcome = await engine.stop()
    let waited = Date().timeIntervalSince(started)
    log("stop returned \(outcome) after \(String(format: "%.2f", waited)) s")
    check(waited < 3, "\(preference): Stop while paused returns within 3 s")
    check(outcome == .ended, "\(preference): Stop while paused confirms the target ended")
    check(await engine.stop() == .ended, "\(preference): a second Stop answers the same")
    opened.closeAll()
    let rows = await scalar("SELECT COUNT(*) FROM probe_log WHERE note = '\(note)'")
    check(rows == "0", "\(preference): insert rolled back after stop while paused (rows=\(rows ?? "?"))")
}

// JDWP ends the target by closing its socket. DBMS_DEBUG cannot reach a routine running between breakpoints: with ALTER
// SYSTEM the supervisor kills the target's session; without it the waiting call says the routine still runs.
func stopRunning(_ preference: OracleDebugProtocolPreference, canKill: Bool = false) async throws {
    log("=== stop while running \(preference)\(canKill ? " with ALTER SYSTEM" : "")")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(pSpin).first else { return }
    let spin = canKill ? 40 : 20
    let engine = try await launch(entry, arguments: ["P_SECONDS": .text(String(spin))], preference: preference, opened: opened)
    let notices = drain(engine)
    log("first: \(describe(try await engine.firstStop()))")
    let running = Task { try await engine.perform(.continueExecution) }
    try await Task.sleep(for: .seconds(3))
    let started = Date()
    let outcome = await engine.stop()
    let waited = Date().timeIntervalSince(started)
    log("stop returned \(outcome) after \(String(format: "%.2f", waited)) s")
    check(waited < 3, "\(preference): Stop while running returns within 3 s")
    if preference == .dbmsDebug, !canKill {
        guard case .unconfirmed(let identity) = outcome, identity?.serial != nil else {
            check(false, "dbmsDebug: Stop without ALTER SYSTEM answers unconfirmed, naming the session")
            return
        }
        check(true, "dbmsDebug: Stop without ALTER SYSTEM answers unconfirmed, naming the session")
    } else {
        check(outcome == .ended, "\(preference): Stop while running confirms the target ended")
    }
    opened.closeAll()
    let result = try? await running.value
    log("waiting continue returned: \(result.map(describe) ?? "threw")")
    log("notices: \(await notices.value)")
    if preference == .dbmsDebug, !canKill {
        guard case .failed(.stillRunning(let identity))? = result else {
            check(false, "dbmsDebug: the waiting Continue says the routine still runs")
            return
        }
        check(identity?.serial != nil, "dbmsDebug: the waiting Continue names the session (\(String(describing: identity)))")
        try await Task.sleep(for: .seconds(Double(spin)))
    } else {
        check(result == .failed(.stopped), "\(preference): the waiting Continue ends as stopped")
        check(waited < Double(spin) - 10, "\(preference): the routine ended before its own end")
    }
    let rows = await scalar("SELECT COUNT(*) FROM probe_log WHERE note = 'spin start'")
    check(rows == "0", "\(preference): the routine's insert rolled back (rows=\(rows ?? "?"))")
}

func fallback() async throws {
    log("=== fallback: no ACE for NOACL")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(fCalc, as: "noacl").first else { check(false, "NOACL sees F_CALC"); return }
    let engine = try await launch(entry, arguments: ["P_A": .text("5")], preference: .automatic, user: "noacl", opened: opened)
    let notices = drain(engine)
    check(engine.mechanism == .dbmsDebug, "automatic fell back to DBMS_DEBUG")
    log("first: \(describe(try await engine.firstStop()))")
    log("end: \(describe(try await engine.perform(.continueExecution)))")
    let all = await notices.value
    log("notices: \(all)")
    check(all.contains { if case .fellBack(.accessControlList, _, _) = $0 { return true }; return false }, "fallback notice names the ACL")
}

func timeoutFallback() async throws {
    log("=== fallback: unreachable host times out")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(fCalc).first else { return }
    let started = Date()
    let engine = try await launch(entry, arguments: ["P_A": .text("5")], preference: .automatic, debuggerHost: unreachableHost, timeout: .seconds(8), opened: opened)
    let notices = drain(engine)
    log("launch took \(String(format: "%.2f", Date().timeIntervalSince(started))) s, mechanism \(engine.mechanism)")
    check(engine.mechanism == .dbmsDebug, "a connect that never arrives falls back to DBMS_DEBUG")
    log("first: \(describe(try await engine.firstStop()))")
    log("end: \(describe(try await engine.perform(.continueExecution)))")
    let all = await notices.value
    log("notices: \(all)")
    let timedOut = all.contains { notice in
        if case .fellBack(.timedOut, _, _) = notice { return true }
        return false
    }
    check(timedOut, "the fallback names the timeout, not the ACL")
}

func privilege() async {
    log("=== privilege: NODEBUG")
    let opened = Opened()
    defer { opened.closeAll() }
    let entry = OracleDebugEntryPoint(entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "NODEBUG", name: "NOPE", kind: .procedure), subprogram: "NOPE", subprogramID: 1), overload: nil, parameters: [], result: nil)
    for preference in [OracleDebugProtocolPreference.jdwp, .dbmsDebug] {
        do {
            _ = try await launch(entry, arguments: [:], preference: preference, user: "nodebug", opened: opened)
            check(false, "\(preference): NODEBUG refused")
        } catch {
            log("\(preference): \(error)")
            check(true, "\(preference): NODEBUG refused")
        }
    }
}

// The address check: a database host that does not resolve to where the connection comes from is refused, and named.
func peerCheck() async throws {
    log("=== peer check: the connection back comes from 127.0.0.1, the database host is given as 127.0.0.2")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(fCalc).first else { return }
    let started = Date()
    let engine = try await launch(entry, arguments: ["P_A": .text("5")], preference: .automatic, databaseHost: "127.0.0.2", opened: opened)
    let notices = drain(engine)
    log("launch took \(String(format: "%.2f", Date().timeIntervalSince(started))) s, mechanism \(engine.mechanism)")
    log("end: \(describe(try await engine.firstStop())) / \(describe(try await engine.perform(.continueExecution)))")
    let all = await notices.value
    log("notices: \(all)")
    let refused = all.contains { notice in
        if case .fellBack(.unexpectedPeer(let seen), _, _) = notice { return seen == ["127.0.0.1"] }
        return false
    }
    check(refused && engine.mechanism == .dbmsDebug, "a peer from another address is refused and named, and the run falls back")
}

// Two overloads of SHOW differ only in P_X's type; the chosen one must run.
func overloads(_ preference: OracleDebugProtocolPreference) async throws {
    log("=== overloads \(preference)")
    let opened = Opened()
    defer { opened.closeAll() }
    let entries = try await entryPoints(overBody)
    log("entry points: \(entries.map(\.displayName))")
    for entry in entries {
        for value in [OracleDebugArgumentValue.text("5"), .null] {
            let engine = try await launch(entry, arguments: ["P_X": value], preference: preference, opened: opened)
            let notices = drain(engine)
            let first = try await engine.firstStop()
            let end = try await engine.perform(.continueExecution)
            let lines = await notices.value.compactMap { notice -> String? in
                if case .serverOutput(let line) = notice { return line }
                return nil
            }
            log("\(entry.displayName) with \(value): first \(describe(first)), \(describe(end)), output \(lines)")
            let type = entry.parameters.first?.dataType == "NUMBER" ? "number" : "varchar2"
            let expected = value == .null ? "\(type) null" : "\(type) 5"
            check(lines == [expected], "\(preference): \(entry.displayName) with \(value) runs its own overload")
        }
    }
}

// The host cancels a start that is still waiting for the database to connect back.
func cancelStart() async throws {
    log("=== cancel while JDWP waits for the database")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(fCalc).first else { return }
    let task = Task {
        try await launch(entry, arguments: ["P_A": .text("5")], preference: .jdwp, debuggerHost: unreachableHost, opened: opened)
    }
    try await Task.sleep(for: .seconds(3))
    let started = Date()
    task.cancel()
    let outcome: String
    do {
        _ = try await task.value
        outcome = "returned a session"
    } catch is CancellationError {
        outcome = "CancellationError"
    } catch {
        outcome = "\(error)"
    }
    let waited = Date().timeIntervalSince(started)
    let targets = opened.lock.withLock { opened.connections }
    log("cancel: \(outcome) after \(String(format: "%.2f", waited)) s; sessions still connected: \(targets.filter(\.isConnected).count) of \(targets.count)")
    check(outcome == "CancellationError" && waited < 8, "a cancelled start throws CancellationError promptly")
    check(targets.count == 2 && !targets[1].isConnected, "the waiting CONNECT_TCP was ended by closing the target's channel")
}

// A startup command that calls the package before CONNECT_TCP: the unit is loaded before the debugger attaches.
func preloaded() async throws {
    log("=== jdwp, the package already ran in the session before CONNECT_TCP")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let run = try await entryPoints(calcBody).first(where: { $0.entry.subprogram == "RUN" }) else { return }
    let engine = try await launch(
        run, arguments: ["P_N": .text("2")], breakpoints: [.init(unit: calcBody, line: 6)], preference: .jdwp,
        startup: "SELECT PROBE.PKG_CALC.ADD_TAX(1) FROM SYS.DUAL", opened: opened
    )
    _ = drain(engine)
    let first = try await engine.firstStop()
    let next = try await engine.perform(.continueExecution)
    log("first \(describe(first)), then \(describe(next))")
    check(first == .paused(OracleDebugLocation(unit: calcBody, line: 9)), "preloaded: the entry stop still comes")
    check(next == .paused(OracleDebugLocation(unit: calcBody, line: 6)), "preloaded: a start-time breakpoint still fires")
    check(await engine.stop() == .ended, "preloaded: Stop while paused answers ended")
}

// Stop while the routine waits in a call that never returns to PL/SQL (DBMS_SESSION.SLEEP): JDWP's closed socket is
// not seen there, so the target is killed, or said to be still running.
func blocked(canKill: Bool) async throws {
    log("=== jdwp, Stop during DBMS_SESSION.SLEEP\(canKill ? " with ALTER SYSTEM" : "")")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(pBlocked).first else { return }
    let engine = try await launch(entry, arguments: [:], breakpoints: [.init(unit: pBlocked, line: 5)], preference: .jdwp, opened: opened)
    let notices = drain(engine)
    _ = try await engine.firstStop()
    let atSelect = try await engine.perform(.continueExecution)
    log("at the sleep: \(describe(atSelect))")
    let running = Task { try await engine.perform(.stepOver) }
    try await Task.sleep(for: .seconds(2))
    let started = Date()
    let outcome = await engine.stop()
    let waited = Date().timeIntervalSince(started)
    let result = try? await running.value
    log("stop returned \(outcome) after \(String(format: "%.2f", waited)) s; waiting step: \(result.map(describe) ?? "threw"); notices \(await notices.value)")
    check(waited < 3, "blocked call: Stop returns within 3 s")
    if canKill {
        check(outcome == .ended, "blocked call with ALTER SYSTEM: Stop confirms the target ended")
        check(result == .failed(.stopped), "blocked call with ALTER SYSTEM: the target is killed and the step ends as stopped")
    } else {
        if case .unconfirmed(let identity) = outcome, identity?.serial != nil {
            check(true, "blocked call without ALTER SYSTEM: Stop answers unconfirmed, naming the session")
        } else {
            check(false, "blocked call without ALTER SYSTEM: Stop answers unconfirmed, naming the session (\(outcome))")
        }
        guard case .failed(.stillRunning(let identity))? = result, identity?.serial != nil else {
            check(false, "blocked call without ALTER SYSTEM: the step says the routine still runs, naming the session")
            return
        }
        check(true, "blocked call without ALTER SYSTEM: the step says the routine still runs (\(String(describing: identity)))")
    }
}

// Stop while stack, variable, source and breakpoint calls run back to back: the one Stop overlaps throws .ended
// promptly, and Stop still ends the target within 3 s.
func stopReading(_ preference: OracleDebugProtocolPreference) async throws {
    log("=== stop during reads \(preference)")
    let opened = Opened()
    defer { opened.closeAll() }
    guard let entry = try await entryPoints(pWrite).first else { return }
    let note = "stop-reading-\(preference.rawValue)"
    let engine = try await launch(entry, arguments: ["P_NOTE": .text(note)], breakpoints: [.init(unit: pWrite, line: 6)], preference: preference, opened: opened)
    _ = drain(engine)
    _ = try await engine.firstStop()
    log("after insert: \(describe(try await engine.perform(.continueExecution)))")
    let (rounds, round) = AsyncStream.makeStream(of: Int.self)
    let reader = Task { () -> (rounds: Int, calls: Int, error: Error?) in
        var finished = 0
        var calls = 0
        do {
            while true {
                calls += 1
                _ = try await engine.stack()
                calls += 1
                _ = try await engine.variables(inFrame: 0)
                calls += 1
                _ = try await engine.source(of: pWrite)
                calls += 1
                _ = try await engine.setBreakpoint(in: pWrite, line: 7)
                calls += 1
                try await engine.removeBreakpoint(in: pWrite, line: 7)
                finished += 1
                round.yield(finished)
            }
        } catch {
            return (finished, calls, error)
        }
    }
    var iterator = rounds.makeAsyncIterator()
    _ = await iterator.next()
    let started = Date()
    let outcome = await engine.stop()
    let waited = Date().timeIntervalSince(started)
    let read = await reader.value
    let readEnded = Date().timeIntervalSince(started)
    log("stop returned \(outcome) after \(String(format: "%.2f", waited)) s; reader ended after \(String(format: "%.2f", readEnded)) s at call \(read.calls) (\(read.rounds) full rounds) with \(String(describing: read.error))")
    check(outcome == .ended, "\(preference): Stop during reads confirms the target ended")
    check(waited < 3, "\(preference): Stop during reads returns within 3 s")
    check(readEnded < 3, "\(preference): the overlapped call ends within 3 s of Stop")
    check((read.error as? OracleDebugError) == .ended, "\(preference): the overlapped call throws .ended")
    opened.closeAll()
    let rows = await scalar("SELECT COUNT(*) FROM probe_log WHERE note = '\(note)'")
    check(rows == "0", "\(preference): insert rolled back after Stop during reads (rows=\(rows ?? "?"))")
}

// PKG_AMBIG.P(x NUMBER DEFAULT 1) and P(x VARCHAR2 DEFAULT 'a'); Q(a NUMBER) and Q(a NUMBER, b VARCHAR2 DEFAULT 'x').
// Oracle refuses a call both overloads match (PLS-00307), so the launcher refuses it before opening a session; a typed
// value runs the chosen overload through either protocol.
func ambiguous() async throws {
    log("=== overloads a call with defaults left out cannot tell apart")
    let entries = try await entryPoints(ambigBody)
    log("entry points: \(entries.map(\.displayName))")
    let ps = entries.filter { $0.entry.subprogram == "P" }
    let qs = entries.filter { $0.entry.subprogram == "Q" }
    guard ps.count == 2, qs.count == 2, let q1 = qs.first(where: { $0.parameters.count == 1 }),
          let q2 = qs.first(where: { $0.parameters.count == 2 }) else {
        check(false, "PKG_AMBIG lists two P and two Q overloads")
        return
    }
    let connection = try await open("probe")
    for call in ["BEGIN pkg_ambig.p; END;", "BEGIN pkg_ambig.q(a => 1); END;"] {
        do {
            _ = try await connection.executeDirect(call)
            check(false, "Oracle refuses \(call)")
        } catch {
            check(String(describing: error).contains("00307"), "Oracle refuses \(call) with PLS-00307")
        }
    }
    connection.disconnect()
    func refused(_ entry: OracleDebugEntryPoint, _ arguments: [String: OracleDebugArgumentValue]) async -> OracleDebugError? {
        let opened = Opened()
        defer { opened.closeAll() }
        do {
            let engine = try await launch(entry, arguments: arguments, preference: .dbmsDebug, overloads: entries, opened: opened)
            _ = await engine.stop()
            return nil
        } catch {
            check(opened.lock.withLock { opened.connections.isEmpty }, "\(entry.displayName): refused before any session opened")
            return error as? OracleDebugError
        }
    }
    for entry in ps {
        let error = await refused(entry, ["X": .defaultValue])
        check(error == .ambiguousDefaults(subprogram: "P", parameters: ["X"]), "\(entry.displayName) with X at its default asks for X (\(String(describing: error)))")
    }
    let q1Error = await refused(q1, ["A": .text("1")])
    check(q1Error == .ambiguousCall(subprogram: "Q"), "\(q1.displayName) is refused as a call no value resolves (\(String(describing: q1Error)))")
    let q2Error = await refused(q2, ["A": .text("1"), "B": .defaultValue])
    check(q2Error == .ambiguousDefaults(subprogram: "Q", parameters: ["B"]), "\(q2.displayName) with B at its default asks for B (\(String(describing: q2Error)))")
    for preference in [OracleDebugProtocolPreference.jdwp, .dbmsDebug] {
        let runs: [(OracleDebugEntryPoint, [String: OracleDebugArgumentValue], String)] = ps.map { entry in
            (entry, ["X": .text("5")], entry.parameters.first?.dataType == "NUMBER" ? "number 5" : "varchar2 5")
        } + [(q2, ["A": .text("1"), "B": .text("y")], "q2 1 y")]
        for (entry, arguments, expected) in runs {
            let opened = Opened()
            defer { opened.closeAll() }
            let engine = try await launch(entry, arguments: arguments, preference: preference, overloads: entries, opened: opened)
            let notices = drain(engine)
            _ = try await engine.firstStop()
            let end = try await engine.perform(.continueExecution)
            let lines = await output(notices)
            log("\(preference) \(entry.displayName): \(describe(end)), output \(lines)")
            check(lines == [expected], "\(preference): \(entry.displayName) with a typed value runs its own overload")
        }
    }
}

let scenarios: [String: () async throws -> Void] = [
    "walk-jdwp": { try await walkthrough(.jdwp) },
    "walk-dbms": { try await walkthrough(.dbmsDebug) },
    "out-jdwp": { try await outputs(.jdwp) },
    "out-dbms": { try await outputs(.dbmsDebug) },
    "stop-paused-jdwp": { try await stopPaused(.jdwp) },
    "stop-paused-dbms": { try await stopPaused(.dbmsDebug) },
    "stop-running-jdwp": { try await stopRunning(.jdwp) },
    "stop-running-dbms": { try await stopRunning(.dbmsDebug) },
    "stop-running-dbms-kill": { try await stopRunning(.dbmsDebug, canKill: true) },
    "fallback": { try await fallback() },
    "timeout": { try await timeoutFallback() },
    "privilege": { await privilege() },
    "peer-check": { try await peerCheck() },
    "overload-jdwp": { try await overloads(.jdwp) },
    "overload-dbms": { try await overloads(.dbmsDebug) },
    "cancel": { try await cancelStart() },
    "preloaded": { try await preloaded() },
    "blocked-jdwp": { try await blocked(canKill: false) },
    "blocked-jdwp-kill": { try await blocked(canKill: true) },
    "stop-reading-jdwp": { try await stopReading(.jdwp) },
    "stop-reading-dbms": { try await stopReading(.dbmsDebug) },
    "ambiguous": { try await ambiguous() },
]
let order = [
    "walk-jdwp", "walk-dbms", "out-jdwp", "out-dbms", "overload-jdwp", "overload-dbms", "ambiguous", "stop-paused-jdwp",
    "stop-paused-dbms", "stop-reading-jdwp", "stop-reading-dbms", "stop-running-jdwp", "stop-running-dbms", "blocked-jdwp", "fallback", "timeout", "peer-check", "cancel", "preloaded",
    "privilege"
]
let chosen = scenario == "all" ? order : scenario.split(separator: ",").map(String.init)
for name in chosen {
    guard let run = scenarios[name] else {
        check(false, "unknown scenario \(name)")
        continue
    }
    do {
        try await run()
    } catch {
        log("\(name) threw: \(error)")
        failures += 1
    }
}
print("failures: \(failures)")
exit(failures == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a few minutes)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$DEBUGGER_HOST" "$UNREACHABLE_HOST" all
status=$?

# The kill branch of Stop (DBMS_DEBUG while running, JDWP inside a call that never returns to PL/SQL) needs ALTER SYSTEM, granted
# for these scenarios only.
echo "grant alter system to probe;" | sql "sys/probe_pw@localhost:1521/FREEPDB1 as sysdba"
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$DEBUGGER_HOST" "$UNREACHABLE_HOST" stop-running-dbms-kill,blocked-jdwp-kill
kill_status=$?
echo "revoke alter system from probe;" | sql "sys/probe_pw@localhost:1521/FREEPDB1 as sysdba"
[ "$status" -eq 0 ] && [ "$kill_status" -eq 0 ]
