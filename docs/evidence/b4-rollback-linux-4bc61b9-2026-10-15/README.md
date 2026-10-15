# B4 rollback layer on current Linux

Source: `4bc61b9396e907978caa045b79d39df8a9db9fd1` (`linux`). The serialized local `b4-rollback` layer passed with Rust/Cargo 1.98.1 and Docker Engine 29.7.2. The layer runner reported a clean tracked tree and both steps exited 0.

| Step | Result |
| --- | --- |
| MySQL/MariaDB `mysql_atomic` | 32 passed, 0 failed, 92 filtered; 231.859 seconds |
| PostgreSQL backend-termination rollback failure | 1 passed, 0 failed, 274 filtered; 20.259 seconds |

Command: `python3 scripts/run-test-layer.py b4-rollback`.

The layer-runner report is preserved in [`manifest.json`](manifest.json). This is local Docker evidence on current Linux. It is not the frozen-candidate Forgejo gate, package-installed acceptance or release qualification. The wider B4-11 and candidate acceptance remain open.
