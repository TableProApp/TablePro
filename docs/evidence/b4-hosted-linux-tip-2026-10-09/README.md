# Hosted B4 acceptance on the merged Linux tip

Build Linux run [37955330433](https://github.com/cozyGarage/BookiE/actions/runs/37955330433)
completed successfully on product commit `97e5f55bddacdfef427c51f162917fedcace3a9f`.
The current `fork/linux` tip `49049e14` is later only because PRs #453 and #454
added documentation and evidence; the application and test sources in this run
match the current tip.

The B4 rollback layer ran the full `mysql_atomic` matrix: 18 MySQL/MariaDB tests
passed, including ARCHIVE, Aria, BLACKHOLE, direct and trigger effects, session
variables, `LAST_INSERT_ID()` and advisory locks. PostgreSQL's backend-
termination rollback-failure selector passed (1 test). The PostgreSQL release
fixture passed, including all seven GTK SSH/mTLS flows and the MySQL approval
dialog regression. The Driver TLS fixture and the staged-release Installed GTK
safety smoke passed. The full workflow also passed driver integration and the
Linux regression gate.

The staged release binary and hosted GTK fixture do not establish a distro
package-manager install or native Wayland acceptance. Windows AD, optional/vendor
MySQL engines, and side effects beyond the recorded matrix remain open.

`manifest.json`, the hosted per-layer reports/logs, and the three B4-22 GTK
scenario captures are preserved here. Their hashes are recorded in the manifest.
