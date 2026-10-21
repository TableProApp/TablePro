#!/usr/bin/env python3
# Driver for scripts/benchmark-app-paths.sh, which builds and signs the app first.

import argparse
import datetime
import json
import math
import os
import platform
import re
import shutil
import signal
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "baseline.json"

TABLE_ROWS = 1_000_000
SWITCH_TABS = 20
RESTORE_CONNECTIONS = 3
RESTORE_TABS = 10
BUDGET_FACTOR = 1.25
SETTLE_SECONDS = 0.5
BENCH_DATABASE = "tablepro_bench"

PATHS = [
    "launch-welcome",
    "launch-restore",
    "table-sqlite",
    "table-mysql",
    "table-postgresql",
    "tabs-next",
    "tabs-recent",
]

LAUNCH_DONE = re.compile(r"^\s+firstFramePresented\s+([0-9.]+)", re.M)
TAB_SWITCH = re.compile(
    r"^tabswitch #\d+ trigger=(\w+) rows=(\w+) outcome=(\w+) totalMs=([0-9.]+)", re.M
)


class BenchmarkError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr, flush=True)


def percentile(values, fraction):
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def summarize(values):
    return {"median": round(statistics.median(values), 1), "p95": round(percentile(values, 0.95), 1)}


def budget_for(value):
    return int(math.ceil(value * BUDGET_FACTOR / 5.0) * 5)


# PluginHostStorage.stableDigest: FNV-1a over the sandbox path.
def defaults_suite(sandbox):
    digest = 0xCBF29CE484222325
    for byte in str(sandbox).encode("utf-8"):
        digest = ((digest ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "com.TablePro.uitest.%016x" % digest


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs)


def osascript(script):
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if result.returncode != 0:
        raise BenchmarkError("osascript failed: %s" % result.stderr.strip())
    return result.stdout.strip()


# Fixtures


def sqlite_rows_sql(table, rows):
    return """
        CREATE TABLE {table} (
            id INTEGER PRIMARY KEY, name TEXT, email TEXT, amount REAL,
            created_at TEXT, status TEXT, note TEXT
        );
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < {rows})
        INSERT INTO {table}
        SELECT i, 'name ' || i, 'user' || i || '@example.com', (i % 100000) / 100.0,
               datetime(1700000000 + i, 'unixepoch'),
               CASE i % 3 WHEN 0 THEN 'open' WHEN 1 THEN 'closed' ELSE 'pending' END,
               'note for row ' || i
        FROM n;
    """.format(table=table, rows=rows)


def make_sqlite(path, tables):
    if path.exists():
        path.unlink()
    connection = sqlite3.connect(str(path))
    try:
        for table, rows in tables:
            connection.executescript(sqlite_rows_sql(table, rows))
        connection.commit()
    finally:
        connection.close()


MYSQL_DIGITS = "(SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 " \
    "UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"


def mysql_command(server, sql, database=None):
    command = ["mysql", "--batch", "--skip-column-names", "-u", server["user"]]
    if server.get("socket"):
        command += ["--protocol=SOCKET", "--socket=%s" % server["socket"]]
    else:
        command += ["--protocol=TCP", "-h", server["host"], "-P", str(server["port"])]
    if database:
        command.append(database)
    return run(command + ["-e", sql]).stdout.strip()


def prepare_mysql(server):
    if shutil.which("mysql") is None:
        raise BenchmarkError("no mysql client on PATH")
    mysql_command(server, "CREATE DATABASE IF NOT EXISTS %s" % BENCH_DATABASE)
    mysql_command(server, """
        CREATE TABLE IF NOT EXISTS bench_rows (
            id INT PRIMARY KEY, name VARCHAR(64), email VARCHAR(128), amount DECIMAL(12,2),
            created_at DATETIME, status VARCHAR(16), note VARCHAR(255)
        );
        CREATE TABLE IF NOT EXISTS bench_small (id INT PRIMARY KEY, name VARCHAR(64));
        INSERT IGNORE INTO bench_small VALUES (1, 'one'), (2, 'two'), (3, 'three');
    """, BENCH_DATABASE)
    count = int(mysql_command(server, "SELECT COUNT(*) FROM bench_rows", BENCH_DATABASE) or 0)
    if count == TABLE_ROWS:
        return
    log("seeding %d rows into MySQL %s.bench_rows" % (TABLE_ROWS, BENCH_DATABASE))
    digits = ", ".join("%s d%d" % (MYSQL_DIGITS, place) for place in range(6))
    number = " + ".join("d%d.d * %d" % (place, 10 ** place) for place in range(6)) + " + 1"
    mysql_command(server, """
        TRUNCATE bench_rows;
        INSERT INTO bench_rows
        SELECT n, CONCAT('name ', n), CONCAT('user', n, '@example.com'), (n % 100000) / 100.0,
               FROM_UNIXTIME(1700000000 + n), ELT(n % 3 + 1, 'open', 'closed', 'pending'),
               CONCAT('note for row ', n)
        FROM (SELECT {number} AS n FROM {digits}) numbers;
        ANALYZE TABLE bench_rows;
    """.format(number=number, digits=digits), BENCH_DATABASE)


def psql_command(server, sql, database="postgres"):
    command = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", server["host"],
               "-p", str(server["port"]), "-U", server["user"], "-d", database, "-c", sql]
    return run(command).stdout.strip()


def prepare_postgres(server):
    if shutil.which("psql") is None:
        raise BenchmarkError("no psql client on PATH")
    exists = psql_command(server, "SELECT 1 FROM pg_database WHERE datname = '%s'" % BENCH_DATABASE)
    if exists != "1":
        psql_command(server, "CREATE DATABASE %s" % BENCH_DATABASE)
    psql_command(server, """
        CREATE TABLE IF NOT EXISTS bench_rows (
            id INT PRIMARY KEY, name TEXT, email TEXT, amount NUMERIC(12,2),
            created_at TIMESTAMP, status TEXT, note TEXT
        );
        CREATE TABLE IF NOT EXISTS bench_small (id INT PRIMARY KEY, name TEXT);
        INSERT INTO bench_small VALUES (1, 'one'), (2, 'two'), (3, 'three') ON CONFLICT DO NOTHING;
    """, BENCH_DATABASE)
    count = int(psql_command(server, "SELECT COUNT(*) FROM bench_rows", BENCH_DATABASE) or 0)
    if count == TABLE_ROWS:
        return
    log("seeding %d rows into PostgreSQL %s.bench_rows" % (TABLE_ROWS, BENCH_DATABASE))
    psql_command(server, """
        TRUNCATE bench_rows;
        INSERT INTO bench_rows
        SELECT n, 'name ' || n, 'user' || n || '@example.com', (n % 100000) / 100.0,
               to_timestamp(1700000000 + n), (ARRAY['open', 'closed', 'pending'])[n % 3 + 1],
               'note for row ' || n
        FROM generate_series(1, {rows}) AS n;
        ANALYZE bench_rows;
    """.format(rows=TABLE_ROWS), BENCH_DATABASE)


def connection_record(name, database_type, sort_order, database, server=None):
    server = server or {"host": "", "port": 0, "user": ""}
    record = {
        "id": str(uuid.uuid4()).upper(),
        "name": name,
        "host": server["host"],
        "port": server["port"],
        "database": database,
        "username": server["user"],
        "type": database_type,
        "sshEnabled": False,
        "sshHost": "",
        "sshUsername": "",
        "sshAuthMethod": "password",
        "sshPrivateKeyPath": "",
        "sortOrder": sort_order,
        "safeModeLevel": "silent",
    }
    # MySQLLocalSocket.fieldKey: without it the driver connects over TCP even to localhost.
    if server.get("socket"):
        record["additionalFields"] = {"localSocketPath": server["socket"]}
    return record


def table_tab(table, database="", quote='"'):
    return {
        "id": str(uuid.uuid4()).upper(),
        "title": table,
        "query": "SELECT * FROM %s%s%s;" % (quote, table, quote),
        "tabType": {"table": {}},
        "tableName": table,
        "databaseName": database,
        "isView": False,
    }


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))


# A TABLEPRO_UI_TEST_SANDBOX template, copied fresh to the same path before every launch.
class Sandbox:

    def __init__(self, work, name):
        self.template = work / "templates" / name
        self.path = work / "sandboxes" / name
        self.support = self.template / "TablePro"
        self.connections = []
        self.open_ids = []

    def add_connection(self, record, tabs, is_open):
        self.connections.append(record)
        if tabs:
            write_json(self.support / "TabState" / ("%s.json" % record["id"]),
                       {"tabs": tabs, "selectedTabId": tabs[0]["id"]})
        if is_open:
            self.open_ids.append(record["id"])

    def finish(self, startup):
        write_json(self.support / "connections.json", self.connections)
        write_json(self.support / "LastOpenConnections.json", self.open_ids)
        (self.support / ".defaults-suite").touch()
        suite = defaults_suite(self.path)
        general = json.dumps({"startupBehavior": startup}).encode("utf-8").hex()
        run(["defaults", "write", suite, "com.TablePro.settings.general", "-data", general])
        # Without it the first launch migrates showWelcome to reopenLast.
        run(["defaults", "write", suite, "com.TablePro.settings.didMigrateStartupToReopenLast", "-bool", "true"])

    def reset(self):
        if self.path.exists():
            shutil.rmtree(self.path)
        shutil.copytree(self.template, self.path)

    def history(self):
        path = self.path / "TablePro" / "TableLoadHistory.jsonl"
        if not path.exists():
            return []
        records = []
        for line in path.read_text().splitlines():
            try:
                records.append(json.loads(line))
            except ValueError:
                continue
        return records

    def delete_defaults(self):
        subprocess.run(["defaults", "delete", defaults_suite(self.path)], capture_output=True)


# Driving the app


class RunningApp:
    def __init__(self, app, sandbox, log_path):
        self.app = app
        self.sandbox = sandbox
        self.log_path = log_path
        self.process = None

    def __enter__(self):
        self.sandbox.reset()
        environment = dict(os.environ)
        environment.update({
            "TABLEPRO_UI_TESTING": "1",
            "TABLEPRO_UI_TEST_SANDBOX": str(self.sandbox.path),
            "TABLEPRO_LAUNCH_TRACE": "1",
            "TABLEPRO_TAB_SWITCH_TRACE": "1",
        })
        binary = self.app / "Contents" / "MacOS" / "TablePro"
        self.log_file = open(self.log_path, "w")
        self.process = subprocess.Popen(
            [str(binary), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            env=environment, stdout=subprocess.DEVNULL, stderr=self.log_file,
        )
        return self

    def __exit__(self, *exc):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log_file.close()

    @property
    def pid(self):
        return self.process.pid

    def output(self):
        return Path(self.log_path).read_text(errors="replace")

    def wait_for(self, describe, check, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise BenchmarkError("TablePro exited with %s while waiting for %s; log: %s"
                                     % (self.process.returncode, describe, self.log_path))
            found = check()
            if found is not None:
                return found
            time.sleep(0.05)
        raise BenchmarkError("timed out waiting for %s; log: %s" % (describe, self.log_path))

    def launch_ms(self):
        match = self.wait_for("the first frame", lambda: LAUNCH_DONE.search(self.output()))
        return float(match.group(1))

    def switches(self):
        return TAB_SWITCH.findall(self.output())

    def bring_forward(self):
        script = 'tell application "System Events" to set frontmost of (first process whose unix id is %d) to true'
        for _ in range(20):
            osascript(script % self.pid)
            time.sleep(0.2)
            front = osascript('tell application "System Events" to get unix id of first process whose frontmost is true')
            if front == str(self.pid):
                return
        raise BenchmarkError("TablePro did not come to the front; is the screen locked?")

    # Every keystroke re-checks the front process, or it lands in whatever the user brought forward.
    def keystroke(self, key, modifiers=()):
        self.bring_forward()
        using = ""
        if modifiers:
            using = " using {%s}" % ", ".join("%s down" % name for name in modifiers)
        if isinstance(key, int):
            action = "key code %d" % key
        else:
            action = 'keystroke "%s"' % key
        osascript('tell application "System Events" to %s%s' % (action, using))


def require_accessibility():
    try:
        front = osascript('tell application "System Events" to get name of first process whose frontmost is true')
    except BenchmarkError as error:
        raise BenchmarkError(
            "System Events refused: give the terminal Accessibility and Automation permission "
            "in System Settings > Privacy & Security (%s)" % error)
    if front == "loginwindow":
        raise BenchmarkError("the screen is locked")


# Paths


def launch_samples(app, sandbox, work, runs, path_name):
    samples = []
    for index in range(runs + 1):
        with RunningApp(app, sandbox, work / ("%s-%d.log" % (path_name, index))) as running:
            value = running.launch_ms()
        if index == 0:
            continue
        samples.append(value)
        log("  %s run %d: %.1f ms" % (path_name, index, value))
    return samples


def welcome_sandbox(work, databases):
    sandbox = Sandbox(work, "launch-welcome")
    for index, database in enumerate(databases):
        record = connection_record("Bench %d" % (index + 1), "SQLite", index, str(database))
        sandbox.add_connection(record, [], is_open=False)
    sandbox.finish("showWelcome")
    return sandbox


def restore_sandbox(work, databases):
    sandbox = Sandbox(work, "launch-restore")
    per_connection = [RESTORE_TABS // RESTORE_CONNECTIONS] * RESTORE_CONNECTIONS
    per_connection[0] += RESTORE_TABS - sum(per_connection)
    for index, (database, count) in enumerate(zip(databases, per_connection)):
        record = connection_record("Bench %d" % (index + 1), "SQLite", index, str(database))
        tabs = [table_tab("t%02d" % (tab + 1)) for tab in range(count)]
        sandbox.add_connection(record, tabs, is_open=True)
    sandbox.finish("reopenLast")
    return sandbox


def completed_loads(sandbox, database_type, row_bucket=None):
    return [
        record for record in sandbox.history()
        if record.get("databaseTypeId") == database_type and record.get("outcome") == "completed"
        and (row_bucket is None or record.get("rowBucket") == row_bucket)
    ]


def table_samples(app, sandbox, work, runs, database_type, path_name):
    samples = []
    with RunningApp(app, sandbox, work / ("%s.log" % path_name)) as running:
        running.launch_ms()
        # A restored tab loads once its window is key.
        running.bring_forward()
        running.wait_for("the restored tab to load",
                         lambda: completed_loads(sandbox, database_type) or None, timeout=60)
        time.sleep(1)
        for index in range(runs + 1):
            before = len(completed_loads(sandbox, database_type, "101-1000"))
            running.keystroke("o", ("command", "shift"))
            time.sleep(0.8)
            running.keystroke("bench_rows")
            time.sleep(0.8)
            running.keystroke(36)
            loads = running.wait_for(
                "bench_rows to load",
                lambda: (completed_loads(sandbox, database_type, "101-1000")[before:] or None),
                timeout=60,
            )
            value = float(loads[0]["totalMs"])
            time.sleep(SETTLE_SECONDS)
            running.keystroke("w", ("command",))
            time.sleep(SETTLE_SECONDS * 2)
            if index == 0:
                continue
            samples.append(value)
            log("  %s run %d: %.1f ms" % (path_name, index, value))
    return samples


def table_sandbox(work, name, record):
    sandbox = Sandbox(work, name)
    database = record["database"] if record["type"] != "SQLite" else ""
    quote = "`" if record["type"] == "MySQL" else '"'
    sandbox.add_connection(record, [table_tab("bench_small", database, quote)], is_open=True)
    sandbox.finish("reopenLast")
    return sandbox


def switch_samples(app, sandbox, work, runs, wanted):
    results = {}
    with RunningApp(app, sandbox, work / "tabs.log") as running:
        running.launch_ms()
        running.bring_forward()
        running.wait_for("the first tab to load",
                         lambda: completed_loads(sandbox, "SQLite") or None, timeout=60)
        time.sleep(1)

        def press(key, modifiers):
            before = len(running.switches())
            running.keystroke(key, modifiers)
            switch = running.wait_for("a tab switch", lambda: running.switches()[before:] or None, timeout=30)[0]
            time.sleep(SETTLE_SECONDS)
            return switch

        log("  visiting all %d tabs once" % SWITCH_TABS)
        for _ in range(SWITCH_TABS):
            press("]", ("command", "shift"))

        for path_name, key, modifiers in (("tabs-next", "]", ("command", "shift")),
                                          ("tabs-recent", 48, ("control",))):
            if path_name not in wanted:
                continue
            results[path_name] = []
            for index in range(runs):
                trigger, rows, outcome, total = press(key, modifiers)
                if outcome != "presented":
                    raise BenchmarkError("%s switch ended %s" % (path_name, outcome))
                results[path_name].append((float(total), rows))
                log("  %s run %d: %s ms (%s)" % (path_name, index + 1, total, rows))
    return results


def switch_sandbox(work, database):
    sandbox = Sandbox(work, "tabs")
    record = connection_record("Bench Tabs", "SQLite", 0, str(database))
    sandbox.add_connection(record, [table_tab("t%02d" % (index + 1)) for index in range(SWITCH_TABS)], True)
    sandbox.finish("reopenLast")
    return sandbox


# Report


def machine():
    def sysctl(name):
        return run(["sysctl", "-n", name]).stdout.strip()

    return {
        "model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "memoryGB": int(sysctl("hw.memsize")) // (1024 ** 3),
        "macOS": platform.mac_ver()[0],
    }


def app_identity(app):
    info = app / "Contents" / "Info.plist"

    def read(key):
        return run(["plutil", "-extract", key, "raw", "-o", "-", str(info)]).stdout.strip()

    debug = (app / "Contents" / "MacOS" / "TablePro.debug.dylib").exists()
    return {
        "version": read("CFBundleShortVersionString"),
        "build": read("CFBundleVersion"),
        "configuration": "Debug" if debug else "Release",
    }


def load_baseline():
    if not BASELINE.exists():
        return None
    return json.loads(BASELINE.read_text())


def report(results, baseline, current_machine, current_app):
    comparable = same_setup(baseline, current_machine, current_app)
    if baseline is not None and not comparable:
        recorded = baseline.get("machine", {})
        log("baseline is from %s, %s GB, %s; this run is %s, %s GB, %s: budgets shown, not enforced" % (
            recorded.get("model"), recorded.get("memoryGB"), baseline.get("app", {}).get("configuration"),
            current_machine["model"], current_machine["memoryGB"], current_app["configuration"]))

    header = "%-18s %5s %9s %9s %17s %17s  %s" % (
        "path", "runs", "median", "p95", "baseline med/p95", "budget med/p95", "status")
    print(header)
    print("-" * len(header))
    over = []
    missing = []
    for name in PATHS:
        if name not in results:
            continue
        summary = results[name]
        expected = (baseline or {}).get("paths", {}).get(name)
        status = "no baseline"
        baseline_text = budget_text = "-"
        if not expected:
            missing.append(name)
        else:
            baseline_text = "%.1f / %.1f" % (expected["median"], expected["p95"])
            budget_text = "%d / %d" % (expected["budgetMedian"], expected["budgetP95"])
            fits = summary["median"] <= expected["budgetMedian"] and summary["p95"] <= expected["budgetP95"]
            status = "ok" if fits else "OVER BUDGET"
            if not fits and comparable:
                over.append(name)
        print("%-18s %5d %9.1f %9.1f %17s %17s  %s" % (
            name, summary["runs"], summary["median"], summary["p95"], baseline_text, budget_text, status))
        if summary.get("rows"):
            print("%-18s %s" % ("", ", ".join("%s %d" % item for item in sorted(summary["rows"].items()))))
    return over, missing


# Memory counts too: it sets how many background tabs keep their rows.
def same_setup(baseline, current_machine, current_app):
    if baseline is None:
        return False
    recorded = baseline.get("machine", {})
    return (
        all(recorded.get(key) == current_machine[key] for key in ("model", "chip", "memoryGB"))
        and baseline.get("app", {}).get("configuration") == current_app["configuration"]
    )


# A path this run did not measure keeps its entry when the baseline came from the same Mac and configuration.
def record_baseline(results, current_machine, current_app, runs):
    previous = load_baseline()
    paths = dict(previous.get("paths", {})) if same_setup(previous, current_machine, current_app) else {}
    for name in PATHS:
        if name not in results:
            continue
        summary = results[name]
        paths[name] = {
            "median": summary["median"],
            "p95": summary["p95"],
            "budgetMedian": budget_for(summary["median"]),
            "budgetP95": budget_for(summary["p95"]),
        }
    BASELINE.write_text(json.dumps({
        "recorded": datetime.date.today().isoformat(),
        "machine": current_machine,
        "app": current_app,
        "runs": runs,
        "budgetRule": "%.2fx the baseline median and p95, rounded up to 5 ms" % BUDGET_FACTOR,
        "paths": {name: paths[name] for name in PATHS if name in paths},
    }, indent=2) + "\n")
    log("wrote %s" % BASELINE)


# The socket the server reports, so the app connects where the client seeded.
def default_mysql_socket():
    if shutil.which("mysql") is None:
        return "127.0.0.1:3306"
    try:
        result = subprocess.run(["mysql", "--batch", "--skip-column-names", "-e", "SELECT @@socket"],
                                capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return "127.0.0.1:3306"
    socket_path = result.stdout.strip()
    return socket_path if result.returncode == 0 and socket_path.startswith("/") else "127.0.0.1:3306"


# user@host:port; for MySQL also user@/path/to.sock. A PostgreSQL host may be a socket directory.
def parse_server(text, default_port, mysql_socket=False):
    match = re.match(r"^(?:([^@]+)@)?([^:]+)(?::(\d+))?$", text)
    if not match:
        raise argparse.ArgumentTypeError("expected user@host:port, got %s" % text)
    user, host, port = match.groups()
    server = {"user": user or os.environ.get("USER", ""), "host": host, "port": int(port or default_port)}
    if mysql_socket and host.startswith("/"):
        server.update({"host": "localhost", "socket": host})
    return server


def main():
    parser = argparse.ArgumentParser(description="Time launch, a large table and tab switches in TablePro.app.")
    parser.add_argument("app", type=Path, help="a signed TablePro.app")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--paths", default=",".join(PATHS), help="comma-separated: " + ", ".join(PATHS))
    parser.add_argument("--mysql", help="user@host:port or user@/path/to.sock; default: the mysql client's own socket")
    parser.add_argument("--postgres", default="127.0.0.1:5432", help="user@host:port")
    parser.add_argument("--record", action="store_true", help="write this run as the baseline")
    parser.add_argument("--keep", action="store_true", help="keep the fixtures and logs")
    options = parser.parse_args()

    wanted = [name.strip() for name in options.paths.split(",") if name.strip()]
    unknown = [name for name in wanted if name not in PATHS]
    if unknown:
        parser.error("unknown path: %s" % ", ".join(unknown))
    try:
        postgres = parse_server(options.postgres, 5432)
        mysql = parse_server(options.mysql, 3306, mysql_socket=True) if options.mysql else None
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))

    busy = os.getloadavg()[0] > os.cpu_count() / 2
    if busy and options.record:
        log("load average %.1f on %d cores: record the baseline on an idle Mac" % (os.getloadavg()[0], os.cpu_count()))
        return 2
    require_accessibility()
    work = Path(tempfile.mkdtemp(prefix="tablepro-benchmark-"))
    log("fixtures and logs: %s" % work)
    sandboxes = []
    results = {}
    skipped = []
    try:
        def add(name, values, rows=None):
            summary = summarize(values)
            summary["runs"] = len(values)
            if rows:
                summary["rows"] = {kind: rows.count(kind) for kind in set(rows)}
            results[name] = summary

        if "launch-welcome" in wanted or "launch-restore" in wanted:
            databases = []
            for index in range(RESTORE_CONNECTIONS):
                path = work / ("restore-%d.sqlite" % (index + 1))
                make_sqlite(path, [("t%02d" % (table + 1), 1000) for table in range(RESTORE_TABS)])
                databases.append(path)
            for name, build in (("launch-welcome", welcome_sandbox), ("launch-restore", restore_sandbox)):
                if name not in wanted:
                    continue
                log(name)
                sandbox = build(work, databases)
                sandboxes.append(sandbox)
                add(name, launch_samples(options.app, sandbox, work, options.runs, name))

        engines = []
        if "table-sqlite" in wanted:
            path = work / "bench.sqlite"
            log("seeding %d rows into %s" % (TABLE_ROWS, path))
            make_sqlite(path, [("bench_rows", TABLE_ROWS), ("bench_small", 3)])
            engines.append(("table-sqlite", connection_record("Bench SQLite", "SQLite", 0, str(path))))
        if "table-mysql" in wanted:
            mysql = mysql or parse_server(default_mysql_socket(), 3306, mysql_socket=True)
            try:
                prepare_mysql(mysql)
                engines.append(("table-mysql", connection_record(
                    "Bench MySQL", "MySQL", 0, BENCH_DATABASE, mysql)))
            except (BenchmarkError, subprocess.CalledProcessError) as error:
                log("skipping table-mysql: %s" % (getattr(error, "stderr", None) or error))
                skipped.append("table-mysql")
        if "table-postgresql" in wanted:
            try:
                prepare_postgres(postgres)
                engines.append(("table-postgresql", connection_record(
                    "Bench PostgreSQL", "PostgreSQL", 0, BENCH_DATABASE, postgres)))
            except (BenchmarkError, subprocess.CalledProcessError) as error:
                log("skipping table-postgresql: %s" % (getattr(error, "stderr", None) or error))
                skipped.append("table-postgresql")
        for name, record in engines:
            log(name)
            sandbox = table_sandbox(work, name, record)
            sandboxes.append(sandbox)
            add(name, table_samples(options.app, sandbox, work, options.runs, record["type"], name))

        if "tabs-next" in wanted or "tabs-recent" in wanted:
            log("tabs")
            path = work / "tabs.sqlite"
            make_sqlite(path, [("t%02d" % (index + 1), 1000) for index in range(SWITCH_TABS)])
            sandbox = switch_sandbox(work, path)
            sandboxes.append(sandbox)
            for name, samples in switch_samples(options.app, sandbox, work, options.runs, wanted).items():
                add(name, [value for value, _ in samples], [rows for _, rows in samples])
    except BenchmarkError as error:
        log("benchmark stopped: %s" % error)
        return 2
    finally:
        for sandbox in sandboxes:
            sandbox.delete_defaults()
        if not options.keep:
            shutil.rmtree(work, ignore_errors=True)

    current_machine = machine()
    current_app = app_identity(options.app)
    print("%s, %s, %d GB, macOS %s; TablePro %s (%s) %s; load average %.1f" % (
        current_machine["model"], current_machine["chip"], current_machine["memoryGB"], current_machine["macOS"],
        current_app["version"], current_app["build"], current_app["configuration"], os.getloadavg()[0]))
    if busy:
        log("the Mac was busy when the run started: these numbers say more about the load than the app")
    over, missing = report(results, load_baseline(), current_machine, current_app)
    if skipped:
        log("not measured: %s" % ", ".join(skipped))
    if options.record:
        if skipped:
            log("baseline not written: every requested path has to be measured")
            return 2
        record_baseline(results, current_machine, current_app, options.runs)
        return 0
    if over:
        return 1
    if missing:
        log("no baseline for %s: record one with --record" % ", ".join(missing))
    return 2 if skipped or missing else 0


if __name__ == "__main__":
    sys.exit(main())
