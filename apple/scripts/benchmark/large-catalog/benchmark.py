#!/usr/bin/env python3
# Driver for scripts/benchmark-large-catalog.sh, which builds and signs the app first.

import argparse
import ctypes
import datetime
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The sandbox, launch and System Events helpers are the app-paths benchmark's; both files are benchmark.py.
_spec = importlib.util.spec_from_file_location("app_paths_benchmark", HERE.parent / "app-paths" / "benchmark.py")
app_paths = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app_paths)

BASELINE = HERE / "baseline.json"

LIBPROC = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


class RusageInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime")]
DATABASE = "tablepro_large_catalog"
# build-large-catalog-fixtures.sh creates the Oracle tenant LC_S001 with this password, whatever SYSTEM's is.
ORACLE_TENANT_PASSWORD = "probe_pw"
STALL_LIMIT_MS = 100
STALL_REPORT_SECONDS = 1.0
STALL_SETTLE_SECONDS = 0.2
SETTLE_SECONDS = 0.6
# The schema each run expands or qualifies, one per run so every read is a first read.
FIRST_RUN_SCHEMA = 50

FIXTURES = ["postgres", "oracle", "mysql"]
# listing: sidebar-listing. session: the filter, Open Quickly, autocomplete and memory. expand: sidebar-expand.
PARTS = ["listing", "session", "expand"]
STEPS = [
    "sidebar-listing",
    "sidebar-filter",
    "sidebar-expand",
    "quick-open-panel",
    "quick-open-result",
    "complete-from",
    "complete-schema",
]

INTERACTION = re.compile(
    r"^interaction #\d+ path=(\w+) outcome=(\w+) totalMs=([0-9.]+) end=([0-9.]+)(.*)$", re.M
)
STALL = re.compile(r"^stall ms=([0-9.]+) end=([0-9.]+)$", re.M)

FOCUS_FILTER = ("f", ("control", "option", "command"))
FOCUS_LIST = ("l", ("control", "option", "command"))
FOCUS_EDITOR = ("e", ("control", "option", "command"))
KEY_DELETE, KEY_ESCAPE, KEY_LEFT, KEY_RIGHT = 51, 53, 123, 124


def log(message):
    app_paths.log(message)


class Fixture:
    def __init__(self, name, record, schema_format, table, password=None, expand_database=None):
        self.name = name
        self.record = record
        self.schema_format = schema_format
        self.table = table
        self.password = password
        # MySQL has no schemas: its expansion is the database in the tree, with nothing browsed.
        self.expand_database = expand_database

    def schema(self, index):
        return self.schema_format % index


def postgres_fixture(server):
    record = app_paths.connection_record("Catalog PostgreSQL", "PostgreSQL", 0, DATABASE, server)
    return Fixture("postgres", record, "lc_s%03d", "lc_t250")


def oracle_fixture(server):
    record = app_paths.connection_record("Catalog Oracle", "Oracle", 0, "FREEPDB1", server)
    record["oracleServiceName"] = "FREEPDB1"
    record["additionalFields"] = {"oracleServiceName": "FREEPDB1"}
    return Fixture("oracle", record, "LC_S%03d", "LC_T250", password=server["password"])


# The mysql client reads MYSQL_PWD for the fixture check; the app needs it in the sandbox's keychain.
def mysql_fixture(server):
    record = app_paths.connection_record("Catalog MySQL", "MySQL", 0, DATABASE, server)
    return Fixture("mysql", record, "", "lc_t00250", password=os.environ.get("MYSQL_PWD") or None,
                   expand_database=DATABASE)


# Fixture checks


def postgres_ready(server):
    if shutil.which("psql") is None:
        return "no psql client on PATH"
    try:
        count = app_paths.psql_command(
            server, "SELECT count(*) FROM pg_tables WHERE schemaname LIKE 'lc!_s%' ESCAPE '!'", DATABASE)
    except subprocess.CalledProcessError as error:
        return error.stderr.strip() or str(error)
    return None if int(count or 0) >= 50000 else "%s tables" % count


def mysql_ready(server):
    if shutil.which("mysql") is None:
        return "no mysql client on PATH"
    try:
        count = app_paths.mysql_command(
            server, "SELECT count(*) FROM information_schema.tables WHERE table_schema = '%s'" % DATABASE)
    except subprocess.CalledProcessError as error:
        return error.stderr.strip() or str(error)
    return None if int(count or 0) >= 50000 else "%s tables" % count


def oracle_ready(container, password):
    if shutil.which("docker") is None:
        return "no docker on PATH"
    sql = "SET HEADING OFF\nSELECT COUNT(*) FROM dba_tables WHERE REGEXP_LIKE(owner, '^LC_S[0-9]+$');\nEXIT\n"
    result = subprocess.run(["docker", "exec", "-i", container, "sqlplus", "-s", "-L", "system/%s@FREEPDB1" % password],
                            input=sql, capture_output=True, text=True)
    numbers = re.findall(r"\d+", result.stdout)
    if result.returncode != 0 or not numbers:
        return (result.stderr or result.stdout).strip() or "no answer"
    return None if int(numbers[-1]) >= 50000 else "%s tables" % numbers[-1]


# Sandboxes


# Oracle is a registry plugin: a published build would time code that is not in this tree.
def oracle_plugin_problem(plugin):
    if plugin is None:
        return "no --oracle-plugin: the release build has no Oracle driver"
    executable = plugin / "Contents" / "MacOS" / "OracleDriver"
    if not executable.exists():
        return "%s has no Contents/MacOS/OracleDriver" % plugin
    sources = [str(HERE.parents[2] / "Plugins" / "OracleDriverPlugin"), str(HERE.parents[2] / "Packages" / "TableProOracle")]
    changed = app_paths.run(["git", "-C", str(HERE), "log", "-1", "--format=%ct", "--"] + sources).stdout.strip()
    if changed and executable.stat().st_mtime < int(changed):
        return "%s was built before this tree's last Oracle change: build OracleDriver from this tree" % plugin
    version = app_paths.run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-",
                             str(plugin / "Contents" / "Info.plist")]).stdout.strip()
    log("Oracle plugin %s, built %s" % (version, datetime.datetime.fromtimestamp(executable.stat().st_mtime)
                                        .strftime("%Y-%m-%d %H:%M")))
    return None


def query_tab():
    return {"id": "00000000-0000-4000-8000-000000003661", "title": "Query 1", "query": "",
            "tabType": {"query": {}}, "databaseName": ""}


def catalog_sandbox(work, name, fixture, layout, plugin=None, database=None, welcome=False):
    sandbox = app_paths.Sandbox(work, name)
    record = dict(fixture.record)
    if database is not None:
        record["database"] = database
    sandbox.add_connection(record, [query_tab()], is_open=not welcome)
    sandbox.finish("showWelcome" if welcome else "reopenLast")
    suite = app_paths.defaults_suite(sandbox.path)
    connection = record["id"]
    app_paths.run(["defaults", "write", suite, "sidebar.layout.%s" % connection, layout])
    if fixture.password:
        app_paths.write_json(sandbox.support / "keychain.json",
                             {"com.TablePro.password.%s" % connection: fixture.password})
    if plugin:
        target = sandbox.support / "Plugins" / plugin.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(plugin, target, symlinks=True)
    return sandbox


# Reading the app's traces


def stalls_in(text):
    return [(float(ms), float(end)) for ms, end in STALL.findall(text)]


# Any stall whose turn overlapped the trace counts, wherever it began or ended.
def worst_stall(trace, stalls):
    start = trace["end"] - trace["ms"] / 1000.0
    overlapping = [ms for ms, end in stalls if end >= start and end - ms / 1000.0 <= trace["end"]]
    return max(overlapping, default=0.0)


# A turn reports its stall only when it ends, so the stalls are scored again once every app has quit.
def rescore(results):
    for traces in results.values():
        for trace in traces:
            trace["stallMs"] = worst_stall(trace, stalls_in(Path(trace["log"]).read_text(errors="replace")))


class Session(app_paths.RunningApp):
    def interactions(self):
        return [
            {"path": path, "outcome": outcome, "ms": float(total), "end": float(end), "detail": detail.strip()}
            for path, outcome, total, end, detail in INTERACTION.findall(self.output())
        ]

    def stalls(self):
        return stalls_in(self.output())

    def count(self, path):
        return len([item for item in self.interactions() if item["path"] == path])

    # The next presented trace of a path after `before` of them, optionally the one whose detail matches.
    def await_trace(self, path, before, describe, detail=None, timeout=120):
        def check():
            found = [item for item in self.interactions() if item["path"] == path][before:]
            found = [item for item in found if item["outcome"] == "presented"
                     and (detail is None or detail in item["detail"].split())]
            return found[0] if found else None

        trace = self.wait_for(describe, check, timeout=timeout)
        if "listing=failed" in trace["detail"].split():
            raise app_paths.BenchmarkError("the all-schema listing failed during %s; log: %s" % (describe, self.log_path))
        self.await_main_thread()
        trace["log"] = self.log_path
        trace["stallMs"] = worst_stall(trace, self.stalls())
        return trace

    # The app answers an accessibility request on its main thread, so the turn the trace ended in, and the
    # stall line it prints when it ends, are done once the answer arrives.
    def await_main_thread(self):
        script = 'tell application "System Events" to count windows of (first process whose unix id is %d)'
        try:
            app_paths.osascript(script % self.pid)
        except app_paths.BenchmarkError:
            time.sleep(STALL_REPORT_SECONDS)
        time.sleep(STALL_SETTLE_SECONDS)

    def key(self, key, modifiers=()):
        self.keystroke(key, modifiers)

    def clear_field(self):
        self.keystroke("a", ("command",))
        self.keystroke(KEY_DELETE)

    # The physical footprint Activity Monitor shows. RSS leaves out what the memory compressor holds, and
    # read 107 to 572 MB for the same retained memory.
    def footprint_mb(self):
        info = RusageInfo()
        if LIBPROC.proc_pid_rusage(self.pid, 0, ctypes.byref(info)) != 0:
            raise app_paths.BenchmarkError("proc_pid_rusage failed for %d" % self.pid)
        return round(info.phys_footprint / 1048576.0, 1)


def launch(app, sandbox, work, label):
    return Session(app, sandbox, work / ("%s.log" % label))


# Steps


# Opened by its tablepro:// link once launch has settled, so the listing is not timed against the launch.
def listing_runs(app, sandbox, work, fixture, runs):
    samples = []
    for index in range(runs):
        with launch(app, sandbox, work, "%s-listing-%d" % (fixture.name, index)) as session:
            session.launch_ms()
            time.sleep(1)
            app_paths.run(["open", "-a", str(app), "tablepro://connect/%s" % fixture.record["id"]])
            trace = session.await_trace("sidebarListing", 0, "the sidebar listing")
            samples.append(trace)
            log("  sidebar-listing run %d: %.1f ms, %s, worst stall %.0f ms"
                % (index + 1, trace["ms"], trace["detail"], trace["stallMs"]))
    return samples


def interactive_runs(app, sandbox, work, fixture, runs, results):
    with launch(app, sandbox, work, "%s-session" % fixture.name) as session:
        session.await_trace("sidebarListing", 0, "the sidebar listing")
        session.bring_forward()
        time.sleep(1)

        samples = []
        for index in range(runs):
            session.key(*FOCUS_FILTER)
            before = session.count("sidebarFilter")
            session.key("7")
            trace = session.await_trace("sidebarFilter", before, "the filtered sidebar", detail="chars=1")
            samples.append(trace)
            log("  sidebar-filter run %d: %.1f ms, %s, worst stall %.0f ms"
                % (index + 1, trace["ms"], trace["detail"], trace["stallMs"]))
            before = session.count("sidebarFilter")
            session.clear_field()
            session.await_trace("sidebarFilter", before, "the cleared sidebar", detail="chars=0")
            time.sleep(SETTLE_SECONDS)
        results["sidebar-filter"] = samples

        panel, result = [], []
        for index in range(runs):
            before = session.count("quickOpenPanel")
            session.key("o", ("command", "shift"))
            panel.append(session.await_trace("quickOpenPanel", before, "the Open Quickly panel"))
            time.sleep(SETTLE_SECONDS)
            before = session.count("quickOpenResult")
            session.key(fixture.table)
            result.append(session.await_trace("quickOpenResult", before, "the first result",
                                              detail="chars=%d" % len(fixture.table)))
            log("  quick-open run %d: panel %.1f ms, result %.1f ms (%s), worst stall %.0f / %.0f ms"
                % (index + 1, panel[-1]["ms"], result[-1]["ms"], result[-1]["detail"],
                   panel[-1]["stallMs"], result[-1]["stallMs"]))
            # The first Escape clears the field, the second closes the panel.
            session.key(KEY_ESCAPE)
            session.key(KEY_ESCAPE)
            time.sleep(SETTLE_SECONDS)
        results["quick-open-panel"] = panel
        results["quick-open-result"] = result

        complete_from, complete_schema = [], []
        session.key(*FOCUS_EDITOR)
        time.sleep(SETTLE_SECONDS)
        for index in range(runs):
            # MySQL has no schemas, so its database is what qualifies a table.
            qualifier = fixture.schema(FIRST_RUN_SCHEMA + 10 + index) if fixture.schema_format else DATABASE
            prompts = [("SELECT * FROM", " ", complete_from), ("SELECT * FROM " + qualifier, ".", complete_schema)]
            for prefix, trigger, samples in prompts:
                session.clear_field()
                session.key(prefix)
                time.sleep(1)
                session.key(KEY_ESCAPE)
                time.sleep(SETTLE_SECONDS)
                before = session.count("completion")
                session.key(trigger)
                trace = session.await_trace("completion", before, "the completion popup after %r" % trigger)
                samples.append(trace)
                log("  complete %r run %d: %.1f ms, %s, worst stall %.0f ms"
                    % (trigger, index + 1, trace["ms"], trace["detail"], trace["stallMs"]))
                session.key(KEY_ESCAPE)
                time.sleep(SETTLE_SECONDS)
        session.clear_field()
        results["complete-from"] = complete_from
        results["complete-schema"] = complete_schema
        return session.footprint_mb()


# Each run opens a schema no run has read, picked by typing its name in the tree.
def expand_runs(session, fixture, runs):
    samples = []
    for index in range(runs):
        session.key(*FOCUS_LIST)
        time.sleep(SETTLE_SECONDS)
        session.key(fixture.schema(FIRST_RUN_SCHEMA + index))
        time.sleep(1.2)
        before = session.count("sidebarExpand")
        session.key(KEY_RIGHT)
        trace = session.await_trace("sidebarExpand", before, "the expanded schema")
        samples.append(trace)
        log("  sidebar-expand run %d: %.1f ms, %s, worst stall %.0f ms"
            % (index + 1, trace["ms"], trace["detail"], trace["stallMs"]))
        session.key(KEY_LEFT)
        time.sleep(SETTLE_SECONDS)
    return samples


def tree_expand_runs(app, sandbox, work, fixture, runs):
    with launch(app, sandbox, work, "%s-tree" % fixture.name) as session:
        session.await_trace("sidebarListing", 0, "the sidebar listing")
        session.bring_forward()
        time.sleep(1)
        return expand_runs(session, fixture, runs)


# A database is read once per launch, so each run of MySQL's expansion is its own launch, in a sandbox
# of its own: the tree keeps what was open in the sandbox's defaults.
def database_expand_runs(app, work, fixture, runs, plugin, sandboxes):
    samples = []
    for index in range(runs):
        sandbox = catalog_sandbox(work, "%s-tree-%d" % (fixture.name, index), fixture, "tree", plugin, database="")
        sandboxes.append(sandbox)
        with launch(app, sandbox, work, "%s-tree-%d" % (fixture.name, index)) as session:
            session.await_trace("sidebarListing", 0, "the sidebar listing")
            session.bring_forward()
            time.sleep(1)
            session.key(*FOCUS_LIST)
            time.sleep(SETTLE_SECONDS)
            session.key(fixture.expand_database)
            time.sleep(1.2)
            before = session.count("sidebarExpand")
            session.key(KEY_RIGHT)
            trace = session.await_trace("sidebarExpand", before, "the expanded database")
            samples.append(trace)
            log("  sidebar-expand run %d: %.1f ms, %s, worst stall %.0f ms"
                % (index + 1, trace["ms"], trace["detail"], trace["stallMs"]))
    return samples


def run_fixture(app, work, fixture, runs, plugin, parts):
    results = {}
    memory = None
    welcome = catalog_sandbox(work, "%s-welcome" % fixture.name, fixture, "flat", plugin, welcome=True)
    flat = catalog_sandbox(work, "%s-flat" % fixture.name, fixture, "flat", plugin)
    sandboxes = [welcome, flat]
    try:
        if "listing" in parts:
            log("%s: sidebar-listing" % fixture.name)
            results["sidebar-listing"] = listing_runs(app, welcome, work, fixture, runs)
        if "session" in parts:
            log("%s: filter, Open Quickly, autocomplete" % fixture.name)
            memory = interactive_runs(app, flat, work, fixture, runs, results)
        if "expand" not in parts:
            pass
        elif fixture.name == "oracle":
            # Oracle lists one row per schema in either layout, so its session's sandbox serves.
            log("%s: sidebar-expand" % fixture.name)
            results["sidebar-expand"] = tree_expand_runs(app, flat, work, fixture, runs)
        elif fixture.name == "postgres":
            tree = catalog_sandbox(work, "%s-tree" % fixture.name, fixture, "tree", plugin)
            sandboxes.append(tree)
            log("%s: sidebar-expand" % fixture.name)
            results["sidebar-expand"] = tree_expand_runs(app, tree, work, fixture, runs)
        elif fixture.expand_database:
            log("%s: sidebar-expand" % fixture.name)
            results["sidebar-expand"] = database_expand_runs(app, work, fixture, runs, plugin, sandboxes)
    finally:
        for sandbox in sandboxes:
            sandbox.delete_defaults()
    rescore(results)
    return results, memory


# Report


def summarize(traces):
    summary = app_paths.summarize([trace["ms"] for trace in traces])
    summary["runs"] = len(traces)
    summary["maxStallMs"] = round(max(trace["stallMs"] for trace in traces), 1)
    return summary


def report(measured, baseline, comparable):
    if baseline is not None and not comparable:
        recorded = baseline.get("machine", {})
        log("baseline is from %s, %s GB, %s; this run is another Mac or build: budgets shown, not enforced; "
            "the %d ms stall limit still is" % (recorded.get("model"), recorded.get("memoryGB"),
                                               baseline.get("app", {}).get("configuration"), STALL_LIMIT_MS))
    header ="%-9s %-18s %5s %9s %9s %10s %17s  %s" % (
        "fixture", "step", "runs", "median", "p95", "max stall", "budget med/p95", "status")
    print(header)
    print("-" * len(header))
    over, missing = [], []
    for fixture in FIXTURES:
        if fixture not in measured:
            continue
        steps = measured[fixture]["steps"]
        expected_steps = ((baseline or {}).get("fixtures", {}).get(fixture) or {}).get("steps", {})
        for step in STEPS:
            if step not in steps:
                continue
            summary = steps[step]
            expected = expected_steps.get(step)
            budget = "-"
            problems = []
            failed = summary["maxStallMs"] > STALL_LIMIT_MS
            if failed:
                problems.append("STALL")
            if not expected:
                missing.append("%s %s" % (fixture, step))
                problems.append("no baseline")
            else:
                budget = "%d / %d" % (expected["budgetMedian"], expected["budgetP95"])
                if summary["median"] > expected["budgetMedian"] or summary["p95"] > expected["budgetP95"]:
                    problems.append("OVER BUDGET")
                    failed = failed or comparable
            if failed:
                over.append("%s %s" % (fixture, step))
            status = ", ".join(problems) or "ok"
            print("%-9s %-18s %5d %9.1f %9.1f %10.1f %17s  %s" % (
                fixture, step, summary["runs"], summary["median"], summary["p95"], summary["maxStallMs"],
                budget, status))
        footprint = measured[fixture]["footprintMB"]
        if footprint is not None:
            entry = (baseline or {}).get("fixtures", {}).get(fixture) or {}
            budget = entry.get("budgetFootprintMB")
            status = "ok"
            if budget is None:
                missing.append("%s footprint" % fixture)
                status = "no baseline"
            elif footprint > budget:
                status = "OVER BUDGET"
                if comparable:
                    over.append("%s footprint" % fixture)
            print("%-9s %-18s %5s %9.1f MB after autocomplete, budget %s MB  %s"
                  % (fixture, "footprint", "", footprint, budget if budget is not None else "-", status))
    return over, missing


# A step or a memory reading this run did not take keeps its entry from a baseline of the same Mac and build.
def record_baseline(measured, current_machine, current_app, runs):
    previous = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    fixtures = dict(previous.get("fixtures", {})) if app_paths.same_setup(previous, current_machine, current_app) else {}
    for fixture, values in measured.items():
        entry = dict(fixtures.get(fixture, {}))
        steps = dict(entry.get("steps", {}))
        for step, summary in values["steps"].items():
            steps[step] = dict(summary, budgetMedian=app_paths.budget_for(summary["median"]),
                               budgetP95=app_paths.budget_for(summary["p95"]))
        entry["steps"] = {step: steps[step] for step in STEPS if step in steps}
        # The RSS this used to keep measured a different thing and has no budget.
        entry.pop("memoryMB", None)
        if values["footprintMB"] is not None:
            entry["footprintMB"] = values["footprintMB"]
            entry["budgetFootprintMB"] = app_paths.budget_for(values["footprintMB"])
        fixtures[fixture] = entry
    BASELINE.write_text(json.dumps({
        "recorded": datetime.date.today().isoformat(),
        "machine": current_machine,
        "app": current_app,
        "runs": runs,
        "budgetRule": "%.2fx the baseline median and p95, rounded up to 5 ms, and the footprint, rounded up to 5 MB; "
                      "no main-thread stall over %d ms" % (app_paths.BUDGET_FACTOR, STALL_LIMIT_MS),
        "fixtures": {name: fixtures[name] for name in FIXTURES if name in fixtures},
    }, indent=2) + "\n")
    log("wrote %s" % BASELINE)


def main():
    parser = argparse.ArgumentParser(description="Time the sidebar, Open Quickly and autocomplete on 50,000 tables.")
    parser.add_argument("app", type=Path, help="a signed TablePro.app")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--fixtures", default=",".join(FIXTURES), help="comma-separated: " + ", ".join(FIXTURES))
    parser.add_argument("--parts", default=",".join(PARTS), help="comma-separated: " + ", ".join(PARTS))
    parser.add_argument("--postgres", default="127.0.0.1:5432", help="user@host:port")
    parser.add_argument("--mysql", help="user@host:port or user@/path/to.sock; default: the mysql client's own socket")
    parser.add_argument("--oracle", default="127.0.0.1:1521", help="host:port of the fixture container's listener")
    parser.add_argument("--oracle-container", default="oracle-large-catalog")
    parser.add_argument("--oracle-password", default="probe_pw", help="SYSTEM's, for the fixture check")
    parser.add_argument("--oracle-plugin", type=Path, help="OracleDriver.tableplugin signed with the TablePro team")
    parser.add_argument("--record", action="store_true", help="write this run as the baseline")
    parser.add_argument("--keep", action="store_true", help="keep the sandboxes and logs")
    options = parser.parse_args()

    wanted = [name.strip() for name in options.fixtures.split(",") if name.strip()]
    parts = [name.strip() for name in options.parts.split(",") if name.strip()]
    unknown = [name for name in wanted if name not in FIXTURES] + [name for name in parts if name not in PARTS]
    if unknown:
        parser.error("unknown fixture or part: %s" % ", ".join(unknown))
    try:
        postgres = app_paths.parse_server(options.postgres, 5432)
        oracle = app_paths.parse_server(options.oracle, 1521)
        mysql = app_paths.parse_server(options.mysql or app_paths.default_mysql_socket(), 3306, mysql_socket=True)
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))

    busy = os.getloadavg()[0] > os.cpu_count() / 2
    if busy and options.record:
        log("load average %.1f on %d cores: record the baseline on an idle Mac" % (os.getloadavg()[0], os.cpu_count()))
        return 2
    app_paths.require_accessibility()
    os.environ["TABLEPRO_INTERACTION_TRACE"] = "1"

    fixtures, skipped = [], []
    for name in wanted:
        if name == "postgres":
            problem, fixture = postgres_ready(postgres), postgres_fixture(postgres)
        elif name == "mysql":
            problem, fixture = mysql_ready(mysql), mysql_fixture(mysql)
        else:
            problem = oracle_ready(options.oracle_container, options.oracle_password) \
                or oracle_plugin_problem(options.oracle_plugin)
            fixture = oracle_fixture({"host": oracle["host"], "port": oracle["port"], "user": "LC_S001",
                                      "password": ORACLE_TENANT_PASSWORD})
        if problem:
            log("skipping %s: %s (scripts/probes/build-large-catalog-fixtures.sh %s builds it)" % (name, problem, name))
            skipped.append(name)
            continue
        fixtures.append(fixture)

    work = Path(tempfile.mkdtemp(prefix="tablepro-catalog-"))
    log("sandboxes and logs: %s" % work)
    measured = {}
    try:
        for fixture in fixtures:
            plugin = options.oracle_plugin if fixture.name == "oracle" else None
            results, memory = run_fixture(options.app, work, fixture, options.runs, plugin, parts)
            measured[fixture.name] = {
                "footprintMB": memory,
                "steps": {step: summarize(traces) for step, traces in results.items()},
            }
    except app_paths.BenchmarkError as error:
        log("benchmark stopped: %s" % error)
        return 2
    finally:
        if not options.keep:
            shutil.rmtree(work, ignore_errors=True)

    current_machine = app_paths.machine()
    current_app = app_paths.app_identity(options.app)
    print("%s, %s, %d GB, macOS %s; TablePro %s (%s) %s; load average %.1f" % (
        current_machine["model"], current_machine["chip"], current_machine["memoryGB"], current_machine["macOS"],
        current_app["version"], current_app["build"], current_app["configuration"], os.getloadavg()[0]))
    if busy:
        log("the Mac was busy when the run started: these numbers say more about the load than the app")
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    comparable = app_paths.same_setup(baseline, current_machine, current_app)
    over, missing = report(measured, baseline, comparable)
    if skipped:
        log("not measured: %s" % ", ".join(skipped))
    if options.record:
        if skipped:
            log("baseline not written: every requested fixture has to be measured")
            return 2
        record_baseline(measured, current_machine, current_app, options.runs)
        return 0
    if over:
        log("over budget: %s" % ", ".join(over))
        return 1
    if missing:
        log("no baseline for %s: record one with --record" % ", ".join(missing))
    return 2 if skipped or missing else 0


if __name__ == "__main__":
    sys.exit(main())
