import importlib.util
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gtk_port_lock", ROOT / "apps/linux/app/tests/gtk_port_lock.py")
port_lock = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(port_lock)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class GtkPortLockTests(unittest.TestCase):
    def setUp(self):
        self.lock_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.lock_dir.cleanup)

    def test_the_context_listens_on_the_port_and_releases_it(self):
        port = free_port()
        with port_lock.listening_on(port, lock_dir=self.lock_dir.name) as server:
            self.assertEqual(server.getsockname()[1], port)
            with socket.create_connection(("127.0.0.1", port), timeout=2):
                pass
        with socket.socket() as again:
            again.bind(("127.0.0.1", port))

    def test_a_second_holder_waits_for_the_first_instead_of_failing_to_bind(self):
        port = free_port()
        entered = []
        first_left = threading.Event()

        def second():
            with port_lock.listening_on(port, lock_dir=self.lock_dir.name, wait_seconds=10):
                entered.append(first_left.is_set())

        with port_lock.listening_on(port, lock_dir=self.lock_dir.name):
            worker = threading.Thread(target=second)
            worker.start()
            time.sleep(0.4)
            self.assertEqual(entered, [])
            first_left.set()
        worker.join(timeout=10)
        self.assertEqual(entered, [True])

    def test_a_holder_that_never_leaves_makes_the_waiter_time_out_clearly(self):
        port = free_port()
        with port_lock.listening_on(port, lock_dir=self.lock_dir.name):
            with self.assertRaises(TimeoutError) as raised:
                with port_lock.listening_on(port, lock_dir=self.lock_dir.name, wait_seconds=0.3):
                    pass
        self.assertIn(str(port), str(raised.exception))

    def test_different_ports_do_not_block_each_other(self):
        with port_lock.listening_on(free_port(), lock_dir=self.lock_dir.name):
            with port_lock.listening_on(free_port(), lock_dir=self.lock_dir.name, wait_seconds=0.3):
                pass


if __name__ == "__main__":
    unittest.main()
