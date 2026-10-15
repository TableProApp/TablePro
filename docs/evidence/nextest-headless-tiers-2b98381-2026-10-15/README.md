# cargo-nextest measurement for headless tiers

Source: BookiE `linux` commit `2b9838114929804b1b140b1af77a50035ee91008`. Host: Omarchy Linux x86_64, kernel 7.2.5-3-omarchy, Rust/Cargo 1.98.1, 16 logical CPUs, 13.5 GiB reported memory. Both runners used the same warmed `CARGO_TARGET_DIR`. The nextest binary was 0.9.148, downloaded from its [official prebuilt releases](https://nexte.st/docs/installation/pre-built-binaries/).

These are one local sample per command, not a CI benchmark. Wall time includes runner startup. Peak memory is a 100 ms sample of summed process-tree `VmRSS`; it can double-count shared pages and is suitable only as a rough comparison. Build output reported 0.19–0.33 seconds for each warmed command.

| Existing selection | `cargo test` | `cargo nextest run` | Sampled peak RSS |
|---|---:|---:|---:|
| Preflight unit packages with `--lib` | 25.86 s; 1,659 passed, 15 ignored | 22.61 s; 1,657 passed, 15 skipped | 2,056.3 MiB vs 2,064.8 MiB |
| Sandbox packages with `--tests`, then Redis `cancellation` test | 68.78 s; 1,628 passed, 56 ignored, plus Redis 1 passed | 42.56 s; 1,623 passed, 56 skipped, plus Redis 1 passed | 2,064.7 MiB vs 1,973.4 MiB |

The selection and ignored-test counts match. Cargo counts subprocess helper invocations as extra test results: two MCP token-store child runs account for the unit count difference, and two storage `process_writer` child runs add two more in the sandbox. The parent tests that launch these helpers passed under both runners. No database containers were started by these selections; Docker-dependent tests remained ignored. The PostgreSQL driver integration suite was not measured.

Nextest was about 13% faster on the unit selection and 38% faster on the sandbox selection in this sample. Sampled peak RSS was effectively unchanged for units and about 4% lower for sandbox. This supports a capped, pinned nextest pilot for these headless tiers, while keeping the current Cargo commands as the required gate until the pilot passes on Forgejo. It does not support applying nextest to the driver tier: PostgreSQL's shared fixture remains process-local and its multi-process startup and isolation costs were not measured here.

Commands mirrored `scripts/preflight.sh` and `scripts/test-sandbox.sh`: the existing package lists and target flags were unchanged; only `cargo test` was replaced by `cargo nextest run` for the comparison. Nextest used its default profile and concurrency, so the results do not assess a capped thread setting.
