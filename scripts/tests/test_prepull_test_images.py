from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepull-test-images.sh"
IMAGES = ROOT / "ci/test-images.txt"

TESTCONTAINERS_MODULES_0_15_IMAGES = {
    "Postgres": ("postgres", "11-alpine"),
    "Mysql": ("mysql", "8.1"),
    "Mongo": ("mongo", "5.0.6"),
    "MssqlServer": ("mcr.microsoft.com/mssql/server", "2022-CU14-ubuntu-22.04"),
    "Redis": ("redis", "5.0"),
}

GROUP_SOURCES = {
    "postgres": "crates/drivers/postgres/tests",
    "mysql": "crates/drivers/mysql/tests",
    "mssql": "crates/drivers/mssql/tests",
    "clickhouse": "crates/drivers/clickhouse/tests",
    "redis": "crates/drivers/redis/tests",
    "mongodb": "crates/drivers/mongodb/tests",
    "app-server": "apps/linux/app",
}
DRIVER_TLS_FIXTURES = ROOT / "tests/fixtures/driver-tls"

MODULE_START = re.compile(r"\b(" + "|".join(TESTCONTAINERS_MODULES_0_15_IMAGES) + r")::default\(\)")
GENERIC_START = re.compile(r'GenericImage::new\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
TAG_ARGUMENT = re.compile(r"with_tag\(\s*([^)]+?)\s*\)")
TAG_CONSTANT = re.compile(r"const ([A-Z_]+):\s*&(?:'static )?str\s*=\s*\"([^\"]+)\"")


def listed_groups():
    groups = {}
    for line in IMAGES.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            group, image = line.split()
            groups.setdefault(group, set()).add(image)
    return groups


def tag_constants(sources):
    constants = {}
    for text in sources.values():
        constants.update(TAG_CONSTANT.findall(text))
    return constants


def module_image(text, match, constants):
    name, default_tag = TESTCONTAINERS_MODULES_0_15_IMAGES[match.group(1)]
    chain = text[match.end() : match.end() + 600]
    start = chain.find(".start()")
    tag = TAG_ARGUMENT.search(chain[: start if start >= 0 else len(chain)])
    if not tag:
        return f"{name}:{default_tag}"
    argument = tag.group(1)
    if argument.startswith('"'):
        return f"{name}:{argument.strip(chr(34))}"
    return f"{name}:{constants[argument.split('::')[-1]]}"


def started_images(directory):
    sources = {path: path.read_text(errors="replace") for path in (ROOT / directory).rglob("*.rs")}
    constants = tag_constants(sources)
    images = set()
    for text in sources.values():
        images.update(module_image(text, match, constants) for match in MODULE_START.finditer(text))
        images.update(f"{name}:{tag}" for name, tag in GENERIC_START.findall(text))
    return images


def fixture_images():
    compose = (DRIVER_TLS_FIXTURES / "docker-compose.yml").read_text()
    images = set(re.findall(r"^\s+image:\s*([^\s#]+)", compose, re.MULTILINE))
    for dockerfile in DRIVER_TLS_FIXTURES.rglob("Dockerfile"):
        images.update(re.findall(r"^FROM\s+(?:--platform=\S+\s+)?([^\s]+)", dockerfile.read_text(), re.MULTILINE))
    return images

STUB = """#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "image inspect")
    grep -qx "$3" "$STUB_PRESENT" 2>/dev/null
    exit $?
    ;;
  "pull --quiet")
    count=$(grep -c "^pull --quiet $3$" "$STUB_LOG")
    [ "$count" -gt "$STUB_FAIL_FIRST" ]
    exit $?
    ;;
esac
exit 0
"""


def run(group, fail_first=0, present=(), images=None):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        stub = tmp / "docker"
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        log = tmp / "log"
        log.write_text("")
        present_file = tmp / "present"
        present_file.write_text("".join(f"{image}\n" for image in present))
        env = dict(
            os.environ,
            PATH=f"{tmp}:{os.environ['PATH']}",
            STUB_LOG=str(log),
            STUB_PRESENT=str(present_file),
            STUB_FAIL_FIRST=str(fail_first),
            PREPULL_BACKOFF_SECONDS="0",
            PREPULL_IMAGE_LIST=str(images or IMAGES),
        )
        result = subprocess.run(["bash", str(SCRIPT), group], env=env, capture_output=True, text=True)
        return result, log.read_text().splitlines()


class PrepullTestImagesTests(unittest.TestCase):
    def test_every_image_in_a_group_is_pulled_once_when_the_pull_works(self):
        result, calls = run("mongodb")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pull --quiet mongo:7", calls)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 1)

    def test_an_image_already_on_the_host_is_not_pulled(self):
        result, calls = run("mongodb", present=["mongo:7"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pull --quiet mongo:7", calls)

    def test_a_dropped_download_is_retried_and_then_succeeds(self):
        result, calls = run("mongodb", fail_first=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 3)

    def test_a_pull_that_never_works_fails_the_step_and_names_the_image(self):
        result, calls = run("mongodb", fail_first=99)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mongo:7", result.stderr)
        self.assertEqual(calls.count("pull --quiet mongo:7"), 3)

    def test_an_unknown_group_is_an_error_not_a_silent_skip(self):
        result, calls = run("no-such-group")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_the_list_covers_each_driver_and_the_tls_fixtures(self):
        groups = {line.split()[0] for line in IMAGES.read_text().splitlines() if line and not line.startswith("#")}
        for group in ("postgres", "mysql", "mssql", "clickhouse", "redis", "mongodb", "driver-tls"):
            self.assertIn(group, groups)

    def test_each_group_pulls_exactly_the_images_its_tests_start(self):
        groups = listed_groups()
        for group, directory in GROUP_SOURCES.items():
            with self.subTest(group=group):
                self.assertEqual(groups.get(group, set()), started_images(directory))

    def test_the_tls_group_pulls_all_fixture_and_compose_images(self):
        self.assertEqual(listed_groups().get("driver-tls", set()), fixture_images())

    def test_a_tag_given_by_constant_resolves_to_that_tag(self):
        text = 'const DB_TAG: &str = "7";\nlet c = Mongo::default().with_tag(DB_TAG).start();'
        match = MODULE_START.search(text)
        self.assertEqual(module_image(text, match, tag_constants({"x": text})), "mongo:7")

    def test_a_module_started_without_a_tag_uses_the_crate_default(self):
        text = "let c = Mysql::default().with_env_var(\"A\", \"b\").start();"
        self.assertEqual(module_image(text, MODULE_START.search(text), {}), "mysql:8.1")

    def test_the_driver_jobs_pre_pull_before_their_tests(self):
        ci = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        self.assertIn('bash src/scripts/prepull-test-images.sh "${{ matrix.driver }}"', ci)
        self.assertIn("bash src/scripts/prepull-test-images.sh driver-tls", ci)

    def test_the_github_fast_job_pre_pulls_before_the_app_server_tests(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        fast = workflow.split("  fast:\n", 1)[1].split("  gtk-safety:\n", 1)[0]
        prepull = fast.index("bash scripts/prepull-test-images.sh app-server")
        self.assertLess(prepull, fast.index("run-test-layer.py app-server"))

    def test_the_fast_job_image_can_run_the_pre_pull_script(self):
        dockerfile = (ROOT / "ci/debian-testing-gtk/Dockerfile").read_text()
        self.assertIn("docker-cli", dockerfile)


if __name__ == "__main__":
    unittest.main()
