#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "feature-parity.py"
SPEC = importlib.util.spec_from_file_location("feature_parity", SCRIPT)
parity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parity)


def registry(*rows):
    features = "".join(
        f"      - name: {name}\n        linux: {linux}\n        windows: {windows}\n" for name, linux, windows in rows
    )
    return f"areas:\n  - name: Area\n    features:\n{features}"


def load(text):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "features.yml"
        path.write_text(text, encoding="utf-8")
        return parity.load(path)


def rendered(text):
    return parity.render(load(text))


class LoadTests(unittest.TestCase):
    def test_yes_and_no_stay_statuses(self):
        [(_, [(_, cells)])] = load(registry(("A feature", "yes", "no")))
        self.assertEqual(cells, [("yes", None, None), ("no", None, None)])

    def test_a_pending_feature_names_its_pull_request(self):
        with self.assertRaisesRegex(parity.RegistryError, "pr names"):
            load(registry(("A feature", "pending", "unknown")))

    def test_only_a_pending_feature_names_a_pull_request(self):
        with self.assertRaisesRegex(parity.RegistryError, "pr names"):
            load(registry(("A feature", "{status: yes, pr: 4121}", "unknown")))

    def test_a_pull_request_is_a_number(self):
        with self.assertRaisesRegex(parity.RegistryError, "not a pull request number"):
            load(registry(("A feature", "{status: pending, pr: soon}", "unknown")))

    def test_a_partial_or_na_feature_says_why(self):
        for status in ("partial", "na"):
            with self.subTest(status=status), self.assertRaisesRegex(parity.RegistryError, "says why"):
                load(registry(("A feature", status, "unknown")))

    def test_an_unknown_status_is_refused(self):
        with self.assertRaisesRegex(parity.RegistryError, "is not one of"):
            load(registry(("A feature", "done", "unknown")))

    def test_a_feature_names_both_apps_and_nothing_else(self):
        missing = "areas:\n  - name: Area\n    features:\n      - name: A feature\n        linux: yes\n"
        with self.assertRaisesRegex(parity.RegistryError, "exactly"):
            load(missing)
        with self.assertRaisesRegex(parity.RegistryError, "exactly"):
            load(registry(("A feature", "yes", "yes")) + "        macos: yes\n")

    def test_a_feature_is_listed_once(self):
        with self.assertRaisesRegex(parity.RegistryError, "listed twice"):
            load(registry(("A feature", "yes", "yes"), ("A feature", "no", "no")))

    def test_a_note_is_one_line(self):
        text = registry(("A feature", "{status: partial, note: x}", "unknown")).replace("note: x", 'note: "a\\nb"')
        with self.assertRaisesRegex(parity.RegistryError, "one line"):
            load(text)


class RenderTests(unittest.TestCase):
    def test_a_pending_feature_links_its_pull_request(self):
        text = rendered(registry(("A feature", "{status: pending, pr: 4121}", "unknown")))
        self.assertIn("| A feature | In [#4121](https://github.com/TableProApp/TablePro/pull/4121) | Unknown |", text)

    def test_a_note_follows_the_status_and_links_its_pull_requests(self):
        text = rendered(registry(("A feature", '{status: partial, note: "tables only, views in #4133"}', "no")))
        link = "[#4133](https://github.com/TableProApp/TablePro/pull/4133)"
        self.assertIn(f"| A feature | Partial: tables only, views in {link} | No |", text)

    def test_a_pipe_does_not_end_the_cell(self):
        text = rendered(registry(("A feature", "{status: na, note: 'a | b'}", "yes")))
        self.assertIn("| n/a: a \\| b | Yes |", text)

    def test_every_status_is_in_the_legend(self):
        text = rendered(registry(("A feature", "yes", "yes")))
        for label, meaning in parity.STATUSES.values():
            self.assertIn(f"| {label} | {meaning} |", text)


if __name__ == "__main__":
    unittest.main()
