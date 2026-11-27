#!/usr/bin/env python3
"""Boot the newest simulator with the given name whose iOS runtime stays mounted, and print its UDID.

The xcode-27 image can unmount a runtime while a job runs (actions/runner-images#14946): xcodebuild still lists
the device, then fails to install with "runtime path not found". A device that does not stay booted is shut down
and the next one tried. When none is left, the runtime it was on is downloaded if it is gone, and every device on
a mounted runtime is tried once more.

Usage:
    python3 scripts/ci/boot-ios-simulator.py <device name>
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

IOS_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-"
# Under the workflow step's 20-minute limit, so the error and the runtime list still print when boots hang.
BUDGET = 15 * 60
BOOT_TIMEOUT = 300
SIMCTL_TIMEOUT = 30
# simdiskimaged unmounts a duplicate runtime 20 to 60 s after a mount or a boot (actions/runner-images#14946).
SETTLE_SECONDS = 60
SETTLE_INTERVAL = 5


def log(text):
    print(text, file=sys.stderr, flush=True)


def simctl_list(kind):
    try:
        result = subprocess.run(["xcrun", "simctl", "list", "-j", kind], capture_output=True, text=True,
                                timeout=SIMCTL_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"xcrun simctl list {kind} timed out")
        return {}
    if result.returncode != 0:
        log(f"xcrun simctl list {kind} failed: {result.stderr.strip()}")
        return {}
    try:
        return json.loads(result.stdout)
    except ValueError:
        log(f"xcrun simctl list {kind} printed no JSON: {result.stdout[:200]}")
        return {}


def simctl(*arguments):
    try:
        subprocess.run(["xcrun", "simctl", *arguments], stdout=sys.stderr, stderr=sys.stderr, timeout=SIMCTL_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"xcrun simctl {' '.join(arguments)} timed out")


def version(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())


def mounted_runtimes(runtimes):
    return {
        runtime["identifier"]: runtime for runtime in runtimes.get("runtimes", [])
        if runtime.get("identifier", "").startswith(IOS_RUNTIME) and runtime.get("isAvailable")
        and os.path.isdir(runtime.get("bundlePath", ""))
    }


def usable_devices(name, devices, runtimes):
    mounted = mounted_runtimes(runtimes)
    found = [
        (version(mounted[runtime].get("version", "")), device)
        for runtime, entries in devices.get("devices", {}).items() if runtime in mounted
        for device in entries if device.get("name") == name and device.get("isAvailable")
    ]
    return [device for _, device in sorted(found, key=lambda pair: pair[0], reverse=True)]


# The newest iOS runtime any device with the name was created on, mounted or not.
def wanted_runtime(name, devices):
    runtimes = [
        runtime for runtime, entries in devices.get("devices", {}).items()
        if runtime.startswith(IOS_RUNTIME) and any(device.get("name") == name for device in entries)
    ]
    return max(runtimes, key=lambda runtime: version(runtime_version(runtime)), default=None)


def runtime_version(runtime):
    return runtime[len(IOS_RUNTIME):].replace("-", ".")


def still_booted(udid, name):
    device = [device for device in usable_devices(name, simctl_list("devices"), simctl_list("runtimes"))
              if device.get("udid") == udid]
    return bool(device) and device[0].get("state") == "Booted"


def boots(udid, name, deadline):
    try:
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True,
                       timeout=min(BOOT_TIMEOUT, deadline - time.monotonic() - SETTLE_SECONDS), stdout=sys.stderr)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        log(f"{udid} did not boot: {error}")
        return False
    settled = time.monotonic() + SETTLE_SECONDS
    while time.monotonic() < settled:
        time.sleep(SETTLE_INTERVAL)
        if not still_booted(udid, name):
            log(f"{udid} booted, then lost its runtime")
            return False
    return True


def boot_first(name, deadline):
    for device in usable_devices(name, simctl_list("devices"), simctl_list("runtimes")):
        if deadline - time.monotonic() <= SETTLE_SECONDS:
            log(f"Out of time to boot another {name}")
            return None
        udid = device["udid"]
        log(f"Booting {name} {udid}")
        if boots(udid, name, deadline):
            return udid
        # All of them: on the 3-core runner a second booted simulator kills runs.
        simctl("shutdown", "all")
    return None


def download(runtime, deadline):
    log(f"Downloading the iOS {runtime_version(runtime)} runtime")
    try:
        result = subprocess.run(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", runtime_version(runtime)],
                                stdout=sys.stderr, timeout=max(deadline - time.monotonic(), 1))
    except subprocess.TimeoutExpired:
        log("The download ran out of time")
        return
    if result.returncode != 0:
        log(f"The download exited {result.returncode}")


def main(arguments):
    if len(arguments) != 1:
        log(__doc__.strip())
        return 2
    name = arguments[0]
    deadline = time.monotonic() + BUDGET
    udid = boot_first(name, deadline)
    wanted = wanted_runtime(name, simctl_list("devices")) if udid is None else None
    if wanted is not None:
        runtimes = simctl_list("runtimes")
        if runtimes and wanted not in mounted_runtimes(runtimes):
            log(f"No {name} simulator stayed booted and the iOS {runtime_version(wanted)} runtime is gone")
            download(wanted, deadline)
        # A runtime whose duplicate simdiskimaged already dropped can stay up on a second boot.
        udid = boot_first(name, deadline)
    if udid is None:
        log(f"::error::No {name} simulator has an iOS runtime it can boot on. xcrun simctl list runtimes:")
        simctl("list", "runtimes")
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
