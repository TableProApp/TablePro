#!/usr/bin/env python3
"""Reads test cases and build errors from .xcresult bundles and swift test xunit files.

Usage:
  xcresult-cases.py tally [--filters <file>] <input>...
      verify.sh's notes, then "<executed> <failed> <filters that ran nothing> <runner failures>"
  xcresult-cases.py errors [--limit <n>] <bundle.xcresult>
      the first n build errors as "<file>:<line>: <message>"
  xcresult-cases.py summary <input>...
      the CI step summary; exits 1 when a bundle or a swift test run executed no test,
      which xcodebuild and swift test both call success

An input is a bundle.xcresult or swift test's X.xml, which also brings X-swift-testing.xml.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from collections import Counter, namedtuple
from itertools import islice
from pathlib import Path

Case = namedtuple("Case", "target suite name label result retried seconds message")

PASSED, FAILED, SKIPPED, EXPECTED = "Passed", "Failed", "Skipped", "Expected Failure"
RUNNER = "System Failure"


def xcresulttool(bundle, *arguments):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", *arguments, "--path", str(bundle), "--compact"],
        capture_output=True, text=True)
    return json.loads(result.stdout) if result.returncode == 0 else None


def descendants(node):
    for child in node.get("children") or []:
        yield child
        yield from descendants(child)


def walk(node, in_system_failures, found):
    if node.get("nodeType") == "Test Case":
        found.append((node, in_system_failures))
        return
    # A runner that crashed or never started is reported as a case in this suite; it is not a test.
    in_system_failures = in_system_failures or (
        node.get("nodeType") == "Test Suite" and node.get("name") == "System Failures")
    for child in node.get("children") or []:
        walk(child, in_system_failures, found)


# A target that ran no case is kept, so the summary can name it.
def bundle_cases(tree):
    result = []
    for plan in (tree or {}).get("testNodes") or []:
        bundles = [node for node in descendants(plan) if (node.get("nodeType") or "").endswith("test bundle")]
        for target in bundles or [plan]:
            name = target.get("name", "?")
            found = []
            walk(target, False, found)
            cases = []
            for node, in_system_failures in found:
                ident = node.get("nodeIdentifier") or node.get("name", "")
                suite, _, case = ident.rpartition("/")
                suite = f"{name}/{suite}" if suite else name
                outcome = RUNNER if in_system_failures else node.get("result")
                if outcome not in (PASSED, SKIPPED, EXPECTED, RUNNER):
                    outcome = FAILED
                message = next((child.get("name", "") for child in descendants(node)
                                if child.get("nodeType") == "Failure Message"), "")
                cases.append(Case(
                    target=name, suite=suite, name=case, label=f"{suite}/{case}", result=outcome,
                    retried=outcome == PASSED and any(
                        child.get("nodeType") == "Repetition" and child.get("result") == FAILED
                        for child in descendants(node)),
                    seconds=node.get("durationInSeconds") or 0.0,
                    message=message if outcome in (FAILED, RUNNER) else ""))
            result.append((name, cases))
    return result


def xunit_sources(path):
    return [source for source in (path, path.with_name(f"{path.stem}-swift-testing.xml")) if source.is_file()]


def xunit_cases(path):
    cases = []
    for source in xunit_sources(path):
        try:
            root = ET.parse(source).getroot()
        except ET.ParseError as error:
            print(f"xcresult-cases.py: cannot read {source}: {error}", file=sys.stderr)
            continue
        for node in root.iter("testcase"):
            # Swift Testing names a nested suite Target.Outer.Inner; swift test filters it as Target.Outer/Inner.
            target, _, nested = node.get("classname", "").partition(".")
            suite = f"{target}.{nested.replace('.', '/')}" if nested else target
            name = node.get("name", "")
            if node.find("skipped") is not None:
                result = SKIPPED
            elif node.find("failure") is not None or node.find("error") is not None:
                result = FAILED
            else:
                result = PASSED
            cases.append(Case(
                target=target, suite=suite, name=name, label=f"{suite}/{name}" if nested else f"{target}.{name}",
                result=result, retried=False, seconds=float(node.get("time") or 0), message=""))
    return cases


def cases_of(argument):
    path = Path(argument)
    if path.suffix == ".xml":
        return xunit_cases(path)
    tree = xcresulttool(path, "test-results", "tests") if path.is_dir() else None
    return [case for _, cases in bundle_cases(tree) for case in cases]


def build_errors(build):
    for issue in (build or {}).get("errors") or []:
        message = issue.get("message", "")
        if message.startswith("Testing cancelled"):
            continue
        url = urllib.parse.urlparse(issue.get("sourceURL") or "")
        path = urllib.parse.unquote(url.path)
        # A document location counts lines from 0.
        start = urllib.parse.parse_qs(url.fragment).get("StartingLineNumber", [""])[0]
        if path and start.isdigit():
            path = f"{path}:{int(start) + 1}"
        yield path, message


def read_filters(path):
    filters = []
    with open(path, encoding="utf-8") as handle:
        for row in filter(None, handle.read().splitlines()):
            fields = row.split("\t")
            pattern = fields[1] if len(fields) > 1 else fields[0]
            try:
                filters.append((fields[0], re.compile(pattern)))
            except re.error:
                filters.append((fields[0], re.compile(re.escape(pattern))))
    return filters


def tally(cases, filters):
    count = Counter(case.result for case in cases)
    executed = [case for case in cases if case.result not in (SKIPPED, RUNNER)]
    targets = {}
    for case in cases:
        if case.result != RUNNER:
            targets.setdefault(case.target, Counter())[case.result == SKIPPED] += 1
    lines = [f"tests: {len(executed)} executed, {count[PASSED]} passed, {count[FAILED]} failed, {count[SKIPPED]} skipped"
             + (f", {count[EXPECTED]} expected failures" if count[EXPECTED] else "")
             + (f", {count[RUNNER]} runner failures" if count[RUNNER] else "")]
    if targets:
        lines.append("targets: " + ", ".join(
            f"{target} {ran[False]}" + (f" ({ran[True]} skipped)" if ran[True] else "")
            for target, ran in targets.items()))
    zero = [label for label, regex in filters if not any(regex.search(case.label) for case in executed)]
    lines += [f"ran nothing: {label}" for label in zero]
    retried = [case.label for case in executed if case.retried]
    if retried:
        lines += ["passed only on retry, a flake to fix:"] + [f"  {label}" for label in retried]
    described = [case for case in cases if case.message][:10]
    if described:
        lines += ["failures:"] + [f"  {case.label}: {case.message.splitlines()[0]}" for case in described]
    lines.append(f"{len(executed)} {count[FAILED]} {len(zero)} {count[RUNNER]}")
    return lines


def summarize(arguments, out, annotations):
    status = 0

    def emit(text=""):
        print(text, file=out)

    def no_test(text):
        nonlocal status
        emit(f"### {text}\n")
        print(f"::error::{text}", file=annotations)
        status = 1

    def listing(heading, labels):
        if not labels:
            return
        if heading:
            emit(heading + "\n")
        emit("\n".join(labels[:50]) + "\n")

    def report(name, cases):
        failed = [case for case in cases if case.result == FAILED]
        minutes = sum(case.seconds for case in cases) / 60
        emit(f"### {name}: {len(cases)} cases, {minutes:.1f} min"
             + (f", {len(failed)} not passing" if failed else "") + "\n")
        listing(None, [f"- failed: `{case.label}`" for case in failed])
        retried = [case.label for case in cases if case.retried]
        listing("Passed only on retry, a flake to fix:", [f"- `{label}`" for label in retried])
        for label in retried:
            print(f"::warning title=Passed only on retry::{label}", file=annotations)
        emit("<details><summary>Slowest 20 cases</summary>\n\n| case | suite | seconds |\n| --- | --- | ---: |")
        for case in sorted(cases, key=lambda case: -case.seconds)[:20]:
            emit(f"| {case.name} | {case.suite} | {case.seconds:.1f} |")
        emit("\n</details>\n")

    for argument in arguments:
        path = Path(argument)
        name = path.stem
        if path.suffix == ".xml":
            if not xunit_sources(path):
                continue
            executed = [case for case in xunit_cases(path) if case.result != SKIPPED]
            if executed:
                report(name, executed)
            else:
                no_test(f"{name}: swift test executed no test")
            continue
        if not path.is_dir():
            continue
        targets = bundle_cases(xcresulttool(path, "test-results", "tests"))
        runner = [case for _, cases in targets for case in cases if case.result == RUNNER]
        # The action log repeats each runner failure as an error, and it is no build error.
        errors = [(where, message) for where, message in build_errors(xcresulttool(path, "build-results"))
                  if not any(message.startswith(case.name) for case in runner)]
        plural = "" if len(errors) == 1 else "s"
        listing(f"### {name}: {len(errors)} build error{plural}",
                [f"- `{where}` {message}" if where else f"- {message}" for where, message in errors])
        executed = []
        for target, cases in targets:
            ran = [case for case in cases if case.result not in (SKIPPED, RUNNER)]
            if not ran:
                no_test(f"{name}: {target} executed no test")
            executed += ran
        plural = "" if len(runner) == 1 else "s"
        listing(f"### {name}: {len(runner)} runner failure{plural} outside any test",
                [f"- `{case.label}`" + (f": {case.message.splitlines()[0]}" if case.message else "")
                 for case in runner])
        if executed:
            report(name, executed)
    return status


def main(arguments):
    command, rest = (arguments[0], arguments[1:]) if arguments else ("", [])
    if command == "tally":
        filters = []
        if rest[:1] == ["--filters"] and len(rest) > 1:
            filters, rest = read_filters(rest[1]), rest[2:]
        print("\n".join(tally([case for argument in rest for case in cases_of(argument)], filters)))
        return 0
    if command == "errors":
        limit = None
        if rest[:1] == ["--limit"] and len(rest) > 1 and rest[1].isdigit():
            limit, rest = int(rest[1]), rest[2:]
        if len(rest) == 1:
            errors = islice(build_errors(xcresulttool(Path(rest[0]), "build-results")), limit)
            for where, message in errors:
                print(f"{Path(where).name}: {message}" if where else message)
            return 0
    if command == "summary":
        destination = os.environ.get("GITHUB_STEP_SUMMARY")
        if not destination:
            return summarize(rest, sys.stdout, sys.stdout)
        with open(destination, "a", encoding="utf-8") as out:
            return summarize(rest, out, sys.stdout)
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
