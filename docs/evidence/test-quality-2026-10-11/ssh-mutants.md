# SSH crate mutation run, 2026-10-11

`cargo mutants -p tablepro-ssh --jobs 3 --timeout 180` on the `linux` tree after #534; 414 mutants in 25 minutes.

| Outcome | Count |
|---|---|
| Mutants generated | 414 |
| Caught | 228 |
| Missed | 62 |
| Timeouts | 12 |
| Unviable | 111 |

About 79 percent of the 290 mutants that built and ran to a verdict (caught plus missed) are caught. Every missed mutant is in [ssh-missed-mutants.txt](ssh-missed-mutants.txt), and the timeouts are in [ssh-timeout-mutants.txt](ssh-timeout-mutants.txt).

## Missed mutants by file

| File | Missed |
|---|---|
| `lib.rs` | 29 |
| `openssh/runtime.rs` | 7 |
| `openssh/supervisor.rs` | 7 |
| `openssh/session.rs` | 5 |
| `bin/tablepro-askpass.rs` | 3 |
| `known_hosts.rs` | 3 |
| `openssh/destination.rs` | 2 |
| `openssh/stderr_classify.rs` | 2 |
| `openssh/sweep.rs` | 2 |
| `openssh/askpass_bridge.rs` | 1 |
| `openssh/prompt.rs` | 1 |

This crate holds host-key trust and the OpenSSH helper code, so the survivors in the host-key and sweep paths come first. A survivor is not automatically a bug: some are equivalent mutants. Triage each one before writing a test, as in the [storage summary](storage-mutants.md). Timeouts need a look too, because a mutant that hangs may hide a missing deadline.
