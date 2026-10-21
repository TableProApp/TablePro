import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleasePublicationTests(unittest.TestCase):
    def test_nested_translation_template_is_collected_with_packages(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        block = workflow.split("      - name: Collect release files\n", 1)[1].split("      - uses:", 1)[0]
        script = "\n".join(line[10:] for line in block.splitlines()[1:] if line.startswith("          "))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            artifacts = base / "artifacts"
            (artifacts / "translations").mkdir(parents=True)
            for name in ["bookie.deb", "bookie.AppImage", "bookie.pkg.tar.zst", "bookie.flatpak", "release-notes.md", "translations/bookie.pot"]:
                (artifacts / name).write_text(name)
            result = subprocess.run(["bash", "-e", "-c", script], cwd=base, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((base / "release/bookie.pot").read_text(), "translations/bookie.pot")
            subprocess.run(["sha256sum", "--check", "SHA256SUMS"], cwd=base / "release", check=True, capture_output=True)

    def load_validator(self):
        spec = importlib.util.spec_from_file_location("release_recovery", ROOT / "scripts/validate-release-recovery.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def fixture(self):
        run = {"head_sha": "a" * 40, "head_branch": "linux-v0.2.0", "event": "push", "path": ".github/workflows/release.yml"}
        jobs = {"jobs": [{"name": name, "conclusion": "success"} for name in ["Debian package", "Arch package", "Flatpak bundle", "AppImage"]]}
        return run, jobs

    def test_successful_packages_can_recover_a_failed_publication(self):
        run, jobs = self.fixture()
        self.load_validator().validate(run, jobs, "linux-v0.2.0", "a" * 40)

    def test_other_source_or_incomplete_packages_are_refused(self):
        validator = self.load_validator()
        for key, value in [("head_sha", "b" * 40), ("head_branch", "linux-v0.1.5"), ("event", "pull_request"), ("path", ".github/workflows/other.yml")]:
            with self.subTest(key=key):
                run, jobs = self.fixture()
                run[key] = value
                with self.assertRaises(ValueError):
                    validator.validate(run, jobs, "linux-v0.2.0", "a" * 40)
        for conclusion in ["failure", "skipped", None]:
            with self.subTest(conclusion=conclusion):
                run, jobs = self.fixture()
                jobs["jobs"][0]["conclusion"] = conclusion
                with self.assertRaises(ValueError):
                    validator.validate(run, jobs, "linux-v0.2.0", "a" * 40)
        run, jobs = self.fixture()
        jobs["jobs"].pop()
        with self.assertRaises(ValueError):
            validator.validate(run, jobs, "linux-v0.2.0", "a" * 40)

    def test_duplicate_package_jobs_are_refused(self):
        run, jobs = self.fixture()
        jobs["jobs"].append({"name": "Arch package", "conclusion": "failure"})
        with self.assertRaises(ValueError):
            self.load_validator().validate(run, jobs, "linux-v0.2.0", "a" * 40)
