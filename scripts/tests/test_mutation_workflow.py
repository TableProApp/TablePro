from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/linux-quality.yml"


class MutationWorkflowTests(unittest.TestCase):
    def test_measurements_fail_the_job_but_keep_later_measurements_running(self):
        text = WORKFLOW.read_text()
        mutation = text.split("  coverage:")[0]
        self.assertNotIn("continue-on-error:", mutation)
        self.assertIn("fail-fast: false", mutation)
        self.assertIn("timeout-minutes: 90", mutation)
        self.assertIn("timeout-minutes: 120", mutation)
        for shard in range(4):
            self.assertIn(f"package: tablepro-core, shard: {shard}/4", mutation)
        for shard in range(2):
            self.assertIn(f"package: tablepro-policy, shard: {shard}/2", mutation)
        self.assertIn("name: mutants-${{ matrix.label }}-${{ github.run_id }}", mutation)
        self.assertIn("if-no-files-found: error", mutation)
        triggers = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("schedule:", triggers)
        self.assertIn("workflow_dispatch:", triggers)
        self.assertNotIn("push:", triggers)
        self.assertIn("cancel-in-progress: false", mutation)
        self.assertIn("--file crates/drivers/postgres/src/decode.rs", mutation)
        self.assertIn("-- --lib", mutation)
        self.assertNotIn("--test integration", mutation)
        self.assertNotIn("--include-ignored", mutation)

    def test_postgres_mutations_include_every_binary_value_decoder(self):
        text = WORKFLOW.read_text().split("  coverage:")[0]
        for module in ["array", "numeric", "temporal", "decode"]:
            self.assertIn(f"--file crates/drivers/postgres/src/{module}.rs", text)

    def test_missing_mutation_reports_cannot_pass_the_summary(self):
        text = WORKFLOW.read_text()
        section = text.split("      - name: Summarise surviving mutants\n", 1)[1]
        section = section.split("      - name: Upload mutation reports", 1)[0]
        script = section.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines())
        script = re.sub(r"\$\{\{.*?\}\}", "success", script)
        with tempfile.TemporaryDirectory() as root:
            summary = Path(root) / "summary.md"
            def run():
                return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=root,
                                      env={"PATH": "/usr/bin:/bin", "GITHUB_STEP_SUMMARY": str(summary), "MUTATION_LABEL": "test"},
                                      capture_output=True, text=True)
            self.assertNotEqual(run().returncode, 0)
            self.assertIn("Measurement unavailable", summary.read_text())
            for crate in ["test"]:
                report = Path(root) / f"mutants-{crate}/mutants.out"
                report.mkdir(parents=True)
                for kind in ["caught", "missed", "timeout", "unviable"]:
                    (report / f"{kind}.txt").write_text("")
            self.assertNotEqual(run().returncode, 0)
            for report in Path(root).glob("mutants-*/mutants.out"):
                (report / "unviable.txt").write_text("mutation did not compile\n")
            self.assertNotEqual(run().returncode, 0)
            for report in Path(root).glob("mutants-*/mutants.out"):
                (report / "caught.txt").write_text("caught mutation\n")
            self.assertEqual(run().returncode, 0)
            (report / "caught.txt").unlink()
            self.assertNotEqual(run().returncode, 0)


if __name__ == "__main__":
    unittest.main()
