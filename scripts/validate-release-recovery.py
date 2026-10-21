import argparse
import json
import os
import re
import subprocess


def validate(run, jobs, tag, source):
    expected = {"head_sha": source, "head_branch": tag, "event": "push", "path": ".github/workflows/release.yml"}
    if any(run.get(key) != value for key, value in expected.items()):
        raise ValueError("The package run does not match the release tag and workflow")
    required = {"Debian package", "Arch package", "Flatpak bundle", "AppImage"}
    for name in required:
        matches = [job for job in jobs.get("jobs", []) if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise ValueError("Every package job must succeed before publication recovery")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id")
    parser.add_argument("tag")
    parser.add_argument("source")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]*", args.run_id):
        parser.error("run_id must be a positive integer")
    if not re.fullmatch(r"linux-v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        parser.error("tag must be linux-vX.Y.Z")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source):
        parser.error("source must be a full commit SHA")
    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{args.run_id}"
    run = json.loads(subprocess.check_output(["gh", "api", endpoint]))
    jobs = json.loads(subprocess.check_output(["gh", "api", f"{endpoint}/jobs?per_page=100"]))
    try:
        validate(run, jobs, args.tag, args.source)
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
