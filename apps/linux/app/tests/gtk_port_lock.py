import contextlib
import fcntl
import socket
import tempfile
import time
from pathlib import Path


@contextlib.contextmanager
def listening_on(port, host="127.0.0.1", lock_dir=None, wait_seconds=180):
    lock_path = Path(lock_dir or tempfile.gettempdir()) / f"tablepro-gtk-port-{port}.lock"
    with open(lock_path, "w") as lock:
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"another run held port {port} for {wait_seconds} seconds") from None
                time.sleep(0.2)
        server = socket.socket()
        try:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((host, port))
            server.listen(4)
            yield server
        finally:
            server.close()
