from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "tests/fixtures/driver-tls/docker-compose.yml"
SERVICE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def service_blocks(text):
    blocks = {}
    current = None
    for line in text.splitlines():
        if line == "services:":
            continue
        match = SERVICE.match(line)
        if match:
            current = match.group(1)
            blocks[current] = []
        elif line and not line.startswith(" ") and current is not None:
            current = None
        elif current is not None:
            blocks[current].append(line)
    return {name: "\n".join(lines) for name, lines in blocks.items()}


class DriverTlsFixtureTests(unittest.TestCase):
    def test_every_mongo_service_restarts_when_mongod_exits_during_initialisation(self):
        # The mongo image runs a temporary mongod to apply /docker-entrypoint-initdb.d
        # seeds. When the final mongod binds 27017 before that instance has released it,
        # it exits 48 (address in use) before any test runs (#924). Docker restarts the
        # container, so the second start binds cleanly.
        blocks = service_blocks(COMPOSE.read_text())
        mongo = sorted(name for name in blocks if "mongo" in name)
        self.assertEqual(mongo, ["mongo", "mongo-plain"])
        for name in mongo:
            with self.subTest(service=name):
                self.assertIn("    restart: on-failure:3", blocks[name].splitlines())


if __name__ == "__main__":
    unittest.main()
