# Tooling boundary regression review

Owner: [#562](https://github.com/cozyGarage/BookiE/issues/562). Source: Linux `180e052a781906b0a2a90cffe43071795642aaa0` plus the test-file contents identified below. The three production helpers are unchanged. These tests pin existing behavior; they do not fix the separate Git disk-error classifier defect in [#1575](https://github.com/cozyGarage/BookiE/issues/1575).

## Tested content

| Test file | SHA-256 |
| --- | --- |
| `scripts/tests/test_classify_ci_failure.py` | `a6857ff2139cdcebe518098d3421de98cdf70c005534f4dcdfee0eb38cabc3a9` |
| `scripts/tests/test_evidence_manifest.py` | `ae813204e42e7436949147981dc4479fea1042b257140dd99cb6e54c851a52d4` |
| `scripts/tests/test_vendor_patches.py` | `e348c585823f0bf5b50343f5dd9ddd18ec5a47376458468c683fb41b401cd4d7` |

The tests cover checksum rejection before extraction, archive destination containment, replay of generated vendor patches, vendor drift and refresh results, evidence digest and pass-count validation, bounded classifier log tails, and fetching logs only for failed jobs. Assertions use outcomes and file contents instead of incidental diagnostic wording. The generated-patch case applies a nonempty patch to its original source and checks the expected text.

## Local validation

- All 62 focused tests pass.
- Coverage.py 7.10.6, matching the workflow pin, ran the full script harness with a fresh coverage-data directory: 443 tests passed.
- Full preflight passed: 443 harness tests, 2,078 unit tests, 2,090 sandbox tests and the separate Redis cancellation test.

| Production helper | Local line/branch coverage |
| --- | ---: |
| `scripts/classify-ci-failure.py` | 92% |
| `scripts/validate-evidence.py` | 96% |
| `scripts/vendor-patches.py` | 91% |
| Combined | 93% |

These whole-file local percentages are not Sonar new-code coverage. A published-branch analysis is required to establish any quality-gate improvement. Forgejo acceptance and independent review are pending.

## Current reference-scan findings

The latest available Sonar analysis inspected on 2026-10-24 is revision `351bb3c8b6a0acfe148975f037e1db7f0b41332f`, dated 10:50:36 UTC. Its gate reports new-code coverage of 74.8% against 80%, and an unsuccessful new-security rating. Four security-rule findings remain open. The GitHub CodeQL alert API reports zero open alerts for Linux; that is a reference-scan state, not a runtime security guarantee.

| Sonar finding | Verified evidence and disposition |
| --- | --- |
| `AaFtisbSXMYMJHNhkuGM`, `json:S6418` | Confirmed false positive: `selected_source_sha256` in the archived architecture manifest contains the SHA-256 of `linux/crates/storage/src/secrets.rs`. The value matches the file at recorded source commit `4b7814f5e1f586c3761c1454e66d3394ad2c9609`; it is a source digest. |
| `AaFtiscUXMYMJHNhkuGN`, `json:S6418` | Confirmed false positive: `changed_source_sha256` in the archived consistency report contains the SHA-256 of `linux/scripts/test-secret-service.sh`. The value matches the file at recorded candidate commit `f8a0ba7055dfe609308aa5326fb10c82982c70b9`. |
| `AaFtV1E95WNdnY_XIBSp`, `docker:S6471` | Confirmed fixture-bootstrap false positive. The fixture inherits `docker-entrypoint.sh` and `mysqld` from MySQL 8.4. In cached image `mysql@sha256:76f0358884cb92d9a086d24e5671c38048d3fef40f2588703d73eb55392d6b69`, entrypoint lines 375–380 create directories and restart as the dedicated mysql user with `exec gosu mysql` before database initialization. The fixture does not replace that entrypoint or command. |
| `AaEqia-IkL-cn5XLtu4p`, `githubactions:S8545` | Further disposition remains open. The workflow installs actionlint at fixed version `v1.7.12` with `GOTOOLCHAIN=go1.25.12`. The release has explicit module requirements. Review the analyzer's lockfile requirement against Go's versioned-tool installation semantics before changing the workflow. |

The source hashes were verified without printing credential values. The MySQL entrypoint was inspected in an owned, read-only, network-disabled container, removed on exit. No Sonar dashboard statuses or source suppressions were changed; authenticated dashboard triage remains pending.

References: [Sonar project](https://sonarcloud.io/dashboard?id=cozyGarage_BookiE), [Go versioned tool installation](https://go.dev/ref/mod#go-install), [actionlint v1.7.12 module requirements](https://github.com/rhysd/actionlint/blob/v1.7.12/go.mod).
