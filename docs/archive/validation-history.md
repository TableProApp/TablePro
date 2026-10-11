# Historical local validation

Archived from `aeac107a4` on 2026-10-03. Reports below retain their original
SHA/scope. Missing cache output cannot establish current acceptance.
Current commands and evidence rules live in [the playbook](../validation-playbook.md).

## Initial implementation evidence, 2026-09-27

Moved from the validation playbook on 2026-10-09. Local reports below are
working-tree evidence based on `1b771214d`, not hosted results for a later
commit. Paths are relative to `linux/target/quality/`.

| Report directory | Result |
| --- | --- |
| `20260926T233834145290Z-layers` | 28 Python runner/workflow tests, standalone function-size regression and actionlint/ShellCheck passed for six Linux workflows |
| `20260926T233421164175Z-layers` | Non-GTK preflight, four isolated GTK widget tests and seven Secret Service tests passed |
| `20260926T232651996488Z-layers` | Policy/MCP tests, cargo-deny 0.20.2 and cargo-audit 0.22.2 passed |
| `20260926T233820141351Z-layers` | Arch candidate validator passed; Debian validator explicitly blocked by missing `dpkg-deb`; aggregate failed |

The runner had 13 focused regression tests, including false-success output,
empty execution, missing tools, timeouts, cancellation, later-layer evidence and
checkout contention. The broader harness totaled 28 unittest cases. Existing
server/TLS/release/UI suites were wired to retained reports; they were not all
rerun locally for that infrastructure change. Hosted workflow execution and
installed-package/Wayland acceptance remain separate evidence.

## October 1–2 local checks

The full layer passed on clean commit `8e7766c`; its report is
[`20261001T235848303064Z-layers/report.json`](../target/quality/20261001T235848303064Z-layers/report.json).
The extended layers have retained individual reports from the same review
sequence; the Docker driver/value runs used the preceding production tree, and
`8e7766c` only adds XLSX cutoff assertions and review documentation.
The app-server/value report is
[`20261001T231537044614Z-layers/report.json`](../target/quality/20261001T231537044614Z-layers/report.json);
Docker drivers, TLS, PostgreSQL release, keyring and security-policy are in
[`20261001T232237703877Z-layers/report.json`](../target/quality/20261001T232237703877Z-layers/report.json).
GTK, audit, workflow/harness and packaging results are retained in the later
per-layer reports under `target/quality/`; each report records its selected
layers, source commit and dirty-tree state.
The October 2 base report is
[`20261001T232237703877Z-layers/report.json`](../target/quality/20261001T232237703877Z-layers/report.json).
The GTK widget and UI safety layers, both supply-chain checks, workflow lint,
test harness, change-contract and Debian packaging layers passed after
installing Xvfb, `cargo-audit`, `python-atspi`, and `dpkg`. The current
`linux/target` already reuses compiled artifacts; it was 82 GiB, including
45 GiB of incremental state, so preserve it for reuse and review cache cleanup
separately.

