#!/usr/bin/env python3
"""Fixture tests for boot-ios-simulator.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("boot_ios_simulator", Path(__file__).with_name("boot-ios-simulator.py"))
boot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot)

NAME = "iPhone 18 Pro"
IOS = "com.apple.CoreSimulator.SimRuntime.iOS-"
FAIL, HANG = "fail", "hang"


class FakeSimulators:
    def __init__(self, root):
        self.root = root
        self.runtimes = []
        self.devices = {}
        self.booted = set()
        self.on_boot = {}
        self.on_tick = {}
        self.ticks = 0
        self.download_status = 0
        self.download_seconds = 0
        self.on_download = None
        self.list_faults = {}
        self.now = 0.0
        self.calls = []

    def runtime(self, version, available=True, mounted=True, platform="iOS"):
        identifier = f"com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace('.', '-')}"
        bundle = self.root / f"{platform} {version}.simruntime"
        if mounted:
            bundle.mkdir()
        self.runtimes.append({
            "identifier": identifier, "version": version, "platform": platform,
            "isAvailable": available, "bundlePath": str(bundle),
        })
        return identifier, bundle

    def device(self, runtime, udid, name=NAME, available=True):
        self.devices.setdefault(runtime, []).append({"udid": udid, "name": name, "isAvailable": available})

    # One entry per boot of the device, in order: FAIL, HANG, or a callable run once it booted.
    def boot_effects(self, udid, *effects):
        self.on_boot[udid] = list(effects)

    def __call__(self, arguments, **options):
        self.calls.append((arguments, options.get("stdout") is sys.stderr, options.get("timeout")))
        if options.get("timeout") is None:
            raise AssertionError(f"{arguments} has no timeout and could block the step")
        if arguments[:4] == ["xcrun", "simctl", "list", "-j"]:
            fault = self.list_faults.get(arguments[4])
            if fault == HANG:
                self.hang(arguments, options["timeout"])
            if fault == FAIL:
                return subprocess.CompletedProcess(arguments, 1, "", "CoreSimulatorService connection became invalid")
            text = "Unable to locate device set" if fault == "garbage" else json.dumps(self.listing(arguments[4]))
            return self.finish(arguments, options, 0, text if options.get("capture_output") else None)
        if arguments[:3] == ["xcrun", "simctl", "bootstatus"]:
            effects = self.on_boot.get(arguments[3]) or [None]
            effect = effects.pop(0)
            if effect == HANG:
                self.hang(arguments, options["timeout"])
            if effect == FAIL:
                return self.finish(arguments, options, 1)
            self.booted.add(arguments[3])
            if effect is not None:
                effect()
            return self.finish(arguments, options, 0)
        if arguments == ["xcrun", "simctl", "shutdown", "all"]:
            self.booted.clear()
        if arguments[:2] == ["xcodebuild", "-downloadPlatform"]:
            if self.download_seconds > options["timeout"]:
                self.hang(arguments, options["timeout"])
            self.now += self.download_seconds
            if self.on_download is not None:
                self.on_download()
            return self.finish(arguments, options, self.download_status)
        return self.finish(arguments, options, 0)

    def hang(self, arguments, timeout):
        self.now += timeout
        raise subprocess.TimeoutExpired(arguments, timeout)

    @staticmethod
    def finish(arguments, options, status, stdout=""):
        if status and options.get("check"):
            raise subprocess.CalledProcessError(status, arguments)
        return subprocess.CompletedProcess(arguments, status, stdout, "")

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        self.ticks += 1
        effect = self.on_tick.pop(self.ticks, None)
        if effect is not None:
            effect()

    def listing(self, kind):
        if kind == "runtimes":
            return {"runtimes": self.runtimes}
        return {"devices": {
            runtime: [{**device, "state": "Booted" if device["udid"] in self.booted else "Shutdown"}
                      for device in entries]
            for runtime, entries in self.devices.items()
        }}

    def commands(self):
        return [arguments for arguments, _, _ in self.calls]

    def downloads(self):
        return [arguments for arguments in self.commands() if arguments[:2] == ["xcodebuild", "-downloadPlatform"]]

    def boots(self):
        return [arguments[3] for arguments in self.commands() if arguments[:3] == ["xcrun", "simctl", "bootstatus"]]


class BootIOSSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.sims = FakeSimulators(self.root)

    def run_script(self):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(boot.subprocess, "run", self.sims), \
                mock.patch.object(boot.time, "sleep", self.sims.sleep), \
                mock.patch.object(boot.time, "monotonic", self.sims.monotonic), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = boot.main([NAME])
        return status, out.getvalue().strip(), err.getvalue()

    def test_boots_the_device_on_the_newest_mounted_runtime(self):
        old, _ = self.sims.runtime("27.0")
        new, _ = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.device(new, "DUO", name="iPhone Duo")
        self.assertEqual(self.run_script()[:2], (0, "NEW"))
        self.assertEqual(self.sims.booted, {"NEW"})
        self.assertEqual(self.sims.ticks, boot.SETTLE_SECONDS // boot.SETTLE_INTERVAL)

    def test_keeps_child_output_off_stdout(self):
        old, _ = self.sims.runtime("27.0")
        new, bundle = self.sims.runtime("27.2", mounted=False)
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.boot_effects("OLD", FAIL, FAIL)
        self.sims.on_download = bundle.mkdir
        self.sims.boot_effects("NEW", FAIL)
        self.assertEqual(self.run_script()[0], 1)
        for command in [["xcrun", "simctl", "shutdown", "all"], ["xcrun", "simctl", "list", "runtimes"]]:
            self.assertIn(command, self.sims.commands())
        for arguments, to_stderr, _ in self.sims.calls:
            if arguments[:4] != ["xcrun", "simctl", "list", "-j"]:
                with self.subTest(arguments=arguments):
                    self.assertTrue(to_stderr)

    def test_skips_a_runtime_listed_as_available_whose_bundle_is_gone(self):
        old, _ = self.sims.runtime("27.0")
        new, _ = self.sims.runtime("27.2", mounted=False)
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.assertEqual(self.run_script()[:2], (0, "OLD"))

    def test_skips_unavailable_devices_runtimes_and_other_platforms(self):
        ios, _ = self.sims.runtime("27.0")
        gone, _ = self.sims.runtime("27.2", available=False)
        watch, _ = self.sims.runtime("27.2", platform="watchOS")
        self.sims.device(ios, "BROKEN", available=False)
        self.sims.device(ios, "GOOD")
        self.sims.device(gone, "GONE")
        self.sims.device(watch, "WATCH")
        self.assertEqual(self.run_script()[:2], (0, "GOOD"))

    def test_moves_on_when_the_runtime_unmounts_during_the_boot(self):
        old, _ = self.sims.runtime("27.0")
        new, bundle = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.boot_effects("NEW", bundle.rmdir)
        status, udid, err = self.run_script()
        self.assertEqual((status, udid), (0, "OLD"))
        self.assertIn(["xcrun", "simctl", "shutdown", "all"], self.sims.commands())
        self.assertIn("NEW booted, then lost its runtime", err)
        self.assertEqual(self.sims.booted, {"OLD"})
        self.assertEqual(self.sims.downloads(), [])

    def test_moves_on_when_the_runtime_unmounts_while_it_settles(self):
        old, _ = self.sims.runtime("27.0")
        new, bundle = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.on_tick[5] = bundle.rmdir
        self.assertEqual(self.run_script()[:2], (0, "OLD"))
        self.assertEqual(self.sims.boots(), ["NEW", "OLD"])

    def test_moves_on_when_the_device_shuts_down_on_a_mounted_runtime(self):
        old, _ = self.sims.runtime("27.0")
        new, _ = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.on_tick[1] = lambda: self.sims.booted.discard("NEW")
        self.assertEqual(self.run_script()[:2], (0, "OLD"))

    def test_moves_on_when_a_boot_fails_or_hangs(self):
        old, _ = self.sims.runtime("27.0")
        new, _ = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.device(new, "SLOW")
        self.sims.boot_effects("NEW", FAIL)
        self.sims.boot_effects("SLOW", HANG)
        status, udid, err = self.run_script()
        self.assertEqual((status, udid), (0, "OLD"))
        self.assertEqual(self.sims.boots(), ["NEW", "SLOW", "OLD"])
        self.assertIn("NEW did not boot", err)
        self.assertIn("SLOW did not boot", err)

    def test_downloads_a_runtime_that_is_gone_and_tries_every_mounted_device_again(self):
        old, _ = self.sims.runtime("27.0")
        new, bundle = self.sims.runtime("27.2", mounted=False)
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.boot_effects("OLD", FAIL, FAIL)
        self.sims.boot_effects("NEW", FAIL)
        self.sims.on_download = bundle.mkdir
        self.assertEqual(self.run_script()[0], 1)
        self.assertEqual(self.sims.downloads(), [["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "27.2"]])
        self.assertEqual(self.sims.boots(), ["OLD", "NEW", "OLD"])

    def test_boots_the_downloaded_runtime(self):
        old, _ = self.sims.runtime("27.0", available=False)
        new, bundle = self.sims.runtime("27.2", mounted=False)
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.on_download = bundle.mkdir
        self.assertEqual(self.run_script()[:2], (0, "NEW"))

    def test_boots_a_device_again_without_a_download_when_its_runtime_is_still_mounted(self):
        new, _ = self.sims.runtime("27.2")
        self.sims.device(new, "NEW")
        self.sims.boot_effects("NEW", lambda: self.sims.booted.discard("NEW"))
        self.assertEqual(self.run_script()[:2], (0, "NEW"))
        self.assertEqual(self.sims.downloads(), [])
        self.assertEqual(self.sims.boots(), ["NEW", "NEW"])

    def test_still_tries_again_when_the_download_fails(self):
        new, bundle = self.sims.runtime("27.2", mounted=False)
        self.sims.device(new, "NEW")
        self.sims.download_status = 70
        self.sims.on_download = bundle.mkdir
        status, udid, err = self.run_script()
        self.assertEqual((status, udid), (0, "NEW"))
        self.assertIn("The download exited 70", err)

    def test_fails_clearly_when_the_download_does_not_bring_the_runtime_back(self):
        new, _ = self.sims.runtime("27.2", mounted=False)
        self.sims.device(new, "NEW")
        status, udid, err = self.run_script()
        self.assertEqual((status, udid), (1, ""))
        self.assertIn(f"::error::No {NAME} simulator has an iOS runtime it can boot on", err)
        self.assertEqual(len(self.sims.downloads()), 1)
        self.assertEqual(self.sims.boots(), [])

    def test_fails_without_a_download_when_no_device_has_the_name(self):
        ios, _ = self.sims.runtime("27.1")
        self.sims.device(ios, "DUO", name="iPhone Duo")
        status, _, err = self.run_script()
        self.assertEqual(status, 1)
        self.assertIn("::error::", err)
        self.assertEqual(self.sims.downloads(), [])

    def test_fails_clearly_when_simctl_cannot_list(self):
        for fault, message in [(FAIL, "CoreSimulatorService connection became invalid"), (HANG, "timed out"),
                               ("garbage", "printed no JSON")]:
            with self.subTest(fault=fault):
                self.sims.list_faults = {"devices": fault, "runtimes": fault}
                status, udid, err = self.run_script()
                self.assertEqual((status, udid), (1, ""))
                self.assertIn(message, err)
                self.assertIn("::error::", err)

    def test_downloads_nothing_when_simctl_cannot_list_the_runtimes(self):
        new, _ = self.sims.runtime("27.2")
        self.sims.device(new, "NEW")
        self.sims.list_faults = {"runtimes": FAIL}
        status, _, err = self.run_script()
        self.assertEqual(status, 1)
        self.assertIn("::error::", err)
        self.assertEqual(self.sims.downloads(), [])

    def test_ends_in_the_error_before_the_step_limit_when_boots_hang(self):
        old, _ = self.sims.runtime("27.0")
        new, _ = self.sims.runtime("27.2")
        self.sims.device(old, "OLD")
        self.sims.device(new, "NEW")
        self.sims.boot_effects("OLD", HANG, HANG)
        self.sims.boot_effects("NEW", HANG, HANG)
        status, _, err = self.run_script()
        self.assertEqual(status, 1)
        self.assertEqual(self.sims.boots(), ["NEW", "OLD", "NEW"])
        self.assertIn("Out of time to boot another", err)
        self.assertIn("::error::", err)
        self.assertIn(["xcrun", "simctl", "list", "runtimes"], self.sims.commands())
        # The last boot's timeout keeps the settle window inside the budget.
        self.assertLessEqual(self.sims.now, boot.BUDGET - boot.SETTLE_SECONDS)

    def test_a_download_that_runs_out_of_time_ends_in_the_error(self):
        new, _ = self.sims.runtime("27.2", mounted=False)
        self.sims.device(new, "NEW")
        self.sims.download_seconds = 3600
        status, _, err = self.run_script()
        self.assertEqual(status, 1)
        self.assertIn("The download ran out of time", err)
        self.assertIn("::error::", err)
        self.assertLessEqual(self.sims.now, boot.BUDGET)

    def test_wanted_runtime_is_the_newest_a_device_was_on(self):
        devices = {"devices": {
            f"{IOS}27-0": [{"name": NAME}],
            f"{IOS}27-10": [{"name": NAME}],
            f"{IOS}27-2": [{"name": NAME}],
            f"{IOS}28-0": [{"name": "iPhone Duo"}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-29-0": [{"name": NAME}],
        }}
        self.assertEqual(boot.wanted_runtime(NAME, devices), f"{IOS}27-10")
        self.assertEqual(boot.runtime_version(f"{IOS}27-10"), "27.10")
        self.assertIsNone(boot.wanted_runtime("iPad", devices))


if __name__ == "__main__":
    unittest.main()
