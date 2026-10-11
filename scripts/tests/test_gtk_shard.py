import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gtk_shard", ROOT / "crates/app/tests/gtk_shard.py")
shard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shard)


class GtkShardTests(unittest.TestCase):
    def test_no_spec_keeps_every_scenario(self):
        self.assertEqual(shard.select(["a", "b", "c"], ""), ["a", "b", "c"])

    def test_the_shards_cover_every_scenario_exactly_once(self):
        items = list("abcdefghij")
        seen = [name for index in (1, 2, 3) for name in shard.select(items, f"{index}/3")]
        self.assertEqual(sorted(seen), items)
        self.assertEqual(len(seen), len(items))

    def test_shards_are_balanced_to_within_one(self):
        sizes = [len(shard.select(list(range(10)), f"{index}/3")) for index in (1, 2, 3)]
        self.assertLessEqual(max(sizes) - min(sizes), 1)

    def test_a_bad_spec_is_refused(self):
        for spec in ("0/3", "4/3", "1/0", "x"):
            with self.assertRaises(ValueError):
                shard.select(["a"], spec)


if __name__ == "__main__":
    unittest.main()
