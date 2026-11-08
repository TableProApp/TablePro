#!/usr/bin/env python3
"""Tests the feature parity registry and the README rendered from it."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

RENDER = Path(__file__).resolve().parents[1] / "parity" / "render.py"
spec = importlib.util.spec_from_file_location("parity_render", RENDER)
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)


def areas_of(text):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "features.yml"
        path.write_text(text, encoding="utf-8")
        return render.load(path)


def feature(extra="", ident="a", macos="yes", linux="yes", windows="unknown"):
    return f"""
areas:
  - name: Area
    features:
      - id: {ident}
        name: A feature
        macos: {macos}
        linux: {linux}
        windows: {windows}
{extra}"""


class ParityTests(unittest.TestCase):
    def test_the_committed_registry_is_valid_and_its_readme_is_current(self):
        areas = render.load()
        self.assertTrue(areas)
        self.assertEqual(render.TARGET.read_text(encoding="utf-8"), render.render(areas))

    def test_a_bare_yes_and_no_are_read_as_statuses(self):
        areas = areas_of(feature(linux="no"))
        cells = areas[0]["features"][0]["cells"]
        self.assertEqual(cells["macos"][0], "yes")
        self.assertEqual(cells["linux"][0], "no")

    def test_a_pending_feature_links_its_pull_request(self):
        text = feature(linux="{status: pending, pr: 4114}")
        rendered = render.render(areas_of(text))
        self.assertIn("In PR [#4114](https://github.com/TableProApp/TablePro/pull/4114)", rendered)

    def test_a_pending_feature_without_a_pull_request_is_refused(self):
        with self.assertRaisesRegex(render.ParityError, "pull request"):
            areas_of(feature(linux="{status: pending}"))

    def test_an_unknown_status_is_refused(self):
        with self.assertRaisesRegex(render.ParityError, "status"):
            areas_of(feature(linux="done"))

    def test_a_missing_platform_is_refused(self):
        text = """
areas:
  - name: Area
    features:
      - id: a
        name: A feature
        macos: yes
        linux: yes
"""
        with self.assertRaisesRegex(render.ParityError, "windows"):
            areas_of(text)

    def test_an_id_is_used_once(self):
        text = feature() + """
      - id: a
        name: Again
        macos: yes
        linux: yes
        windows: yes
"""
        with self.assertRaisesRegex(render.ParityError, "twice"):
            areas_of(text)

    def test_a_pipe_in_a_note_does_not_break_the_table(self):
        rendered = render.render(areas_of(feature(linux="{status: partial, note: 'a | b'}")))
        self.assertIn("Partial: a \\| b", rendered)


if __name__ == "__main__":
    unittest.main()
