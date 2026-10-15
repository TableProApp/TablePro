# Remaining-gap acceptance, 2026-10-15

## Distro diagnostics

[#949](https://github.com/cozyGarage/BookiE/pull/949) merged as `b9a8d64e974fd60fcf6712f2f13b58b03ea09af1` and closed [#937](https://github.com/cozyGarage/BookiE/issues/937). Exact PR head `cf97a05fc61482cfe25ae020f157264579accb1b` passed Forgejo run 508, all 28 jobs including both distro floors. Required GitHub checks and CodeQL passed. SonarCloud reported only 0% tooling coverage, the existing TEST-34 import gap, accepted as nonblocking under the contributor rules and maintainer authorization.

Forgejo Linux sync run 510 passed all 28 jobs at the merged commit.

The GitHub and Forgejo PR branches and the local review branch were removed. [Regression evidence](distro-floor-diagnostics-2026-10-15.md) records the failing-first mixed success/error log.

## Independent guard finding

[#961](https://github.com/cozyGarage/BookiE/issues/961), TEST-35, records the separate panic-guard module-resolution defect. An isolated tree declared production `src/tests.rs` from its crate root and test-only `src/parent/tests.rs` from `src/parent.rs`. The unchanged guard incorrectly marked the production sibling as test-only and returned 0 despite its explicit production panic. The ordinary nested test module also produced a false-positive failure in completion preflight.

The completion PR uses the existing explicit-path convention. The guard change remains a focused UX backlog issue, P2, high confidence. This probe does not claim a production panic exists in BookiE.

## Exact SQL proposals

[#960](https://github.com/cozyGarage/BookiE/pull/960) addresses [#934](https://github.com/cozyGarage/BookiE/issues/934) at head `1a4f153fa282a9540d8a4ed85921d92bf3f39cb1`. All six GitHub workflows passed, including [Build Linux](https://github.com/cozyGarage/BookiE/actions/runs/38792221006), [CodeQL](https://github.com/cozyGarage/BookiE/actions/runs/38792220882), [Flatpak](https://github.com/cozyGarage/BookiE/actions/runs/38792220977) and [Sonar Rust](https://github.com/cozyGarage/BookiE/actions/runs/38792220892). Sonar reports zero open findings for the PR.

Forgejo run 512 passed all 28 jobs on that exact head. The latest Linux base was already included; no post-gate code change or gate-reuse exception was needed. The PR merged as `75bb47fc69348c82ea80be33872d39de707463a5` and closed #934. Its project item is Done. GitHub and Forgejo feature branches and the local branch were removed.

[Local regression evidence](sql-identifier-proposals-2026-10-15.md) records the failing-first boundary cases, all 52 widget tests, eight pure proposal regressions and native PostgreSQL identity check. Desktop keyboard and screen reader checks remain manual.

Forgejo Linux sync run 514 passed all 28 jobs at the immutable merged commit. The documentation-only acceptance record follows on GitHub Linux; it does not queue another Forgejo run or move its code tip.

## Disconnect cache follow-up

[#963](https://github.com/cozyGarage/BookiE/issues/963) records a separate pre-existing teardown gap, P3, UX. Source tracing at the merged commit confirms disconnect retains the shared completion index and table list, while the always-enabled editor action can create a fresh offline editor using that index. New connection activation already refreshes table names and generation; late callbacks already refuse a missing connection. No wrong-database execution is claimed. The installed disconnect/reopen sequence remains to be reproduced by the issue’s first regression.
