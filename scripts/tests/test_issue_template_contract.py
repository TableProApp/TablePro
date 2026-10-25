from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IssueTemplateContractTests(unittest.TestCase):
    def test_feature_request_template_asks_for_user_visible_acceptance(self):
        template = (ROOT / ".github/ISSUE_TEMPLATE/feature_request.yml").read_text()

        self.assertIn("label: User-visible acceptance scenarios", template)
        self.assertIn("Given <starting state>", template)
        self.assertIn("When <user action>", template)
        self.assertIn("Then <observable outcome>", template)

    def test_pull_request_template_connects_acceptance_to_regression_evidence(self):
        template = (ROOT / ".github/pull_request_template.md").read_text()

        self.assertIn("Given / When / Then", template)
        self.assertIn("Name the regression test", template)
        self.assertIn("manual acceptance step", template)

    def test_bug_report_keeps_reproduction_and_environment_fields(self):
        template = (ROOT / ".github/ISSUE_TEMPLATE/bug_report.yml").read_text()

        for expected in ("Remove passwords, tokens", "id: steps", "id: linux", "id: desktop", "id: install_method"):
            with self.subTest(expected=expected):
                self.assertIn(expected, template)


if __name__ == "__main__":
    unittest.main()
