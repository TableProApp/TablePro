import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FloorAptConfigTests(unittest.TestCase):
    def test_floor_images_bound_network_waits_before_installing_packages(self):
        for name in ('Dockerfile', 'Dockerfile.runtime'):
            with self.subTest(image=name):
                text = (ROOT / 'scripts/distro-floor' / name).read_text()
                first_install = text.index('apt-get update')
                for setting, value in [('Retries', 3), ('http::Timeout', 30), ('https::Timeout', 30)]:
                    match = re.search(r'Acquire::' + re.escape(setting) + r'\s+"(\d+)";', text)
                    self.assertIsNotNone(match, setting)
                    self.assertEqual(int(match[1]), value)
                    self.assertLess(match.start(), first_install)


if __name__ == '__main__':
    unittest.main()
