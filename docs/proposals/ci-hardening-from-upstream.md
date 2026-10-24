# CI hardening ideas from upstream TablePro

Proposed; none of this is accepted or scheduled. It records what a review of TablePro's CI at `main` commit `5533f2e7` (pushed 2026-10-24) found that BookiE does not do, after the four low-risk items below were made. Forgejo remains the merge gate and the GitHub tier stays cheap ([ADR 0020](../decisions/0020-aggregate-forgejo-trains.md), [validation playbook](../validation-playbook.md#ci-tiers)). Ideas for the `.forgejo` workflows go through the app-side session.

## Already made

- `persist-credentials: false` on every GitHub checkout, and a `workflow-security` job running `zizmor` offline (pinned, medium severity and confidence). The review found 18 checkouts that kept credentials and one template injection in the soak summary.
- A `PR title` check, because the title is now the squash subject, and a guard that only a `chore(release)` pull request edits `CHANGELOG.md`.
- The Release workflow refuses a tagged commit that is not on `linux`.

## Open questions

1. **`Swatinem/rust-cache` in the publishing workflow.** `zizmor` reports low-confidence cache-poisoning findings at two steps in `release.yml` (the `.deb` and Arch package jobs). A tag build can restore a cache written earlier on `linux`. Decide whether the release jobs should build without the cache, or record the exception with its reason. These findings are filtered out of the gate by the confidence setting, so nothing flags them today.
2. **Unused dependencies.** Upstream runs `cargo shear`. BookiE has `cargo deny` through the security layer and `cargo-about` notices scripts, but no unused-dependency check. Also confirm that CI fails when the generated third-party notices differ from `Cargo.lock`; I did not verify that.
3. **Build without default features.** BookiE has an optional DuckDB feature, and no CI step builds the workspace with `--no-default-features`. Upstream runs it in its nightly. A cheap `cargo check --workspace --all-targets --locked --no-default-features` would cover it.
4. **Where a change is compared from.** Upstream's planner compares a push to `main` with the last commit whose CI run passed, so a cancelled or replaced run's changes are tested again. BookiE's path filters compare against the previous push. This matters for the Forgejo gate more than for GitHub.
5. **Release environment.** Upstream releases through a protected environment with a required reviewer that is limited to release tags. Consider the same for the GitHub release job.

## Not worth copying

A single `ci.yml` entry with one aggregate check (BookiE has `regression-gate` and the Forgejo gate), the path-selection script (BookiE has `change-test-map.json`), and the Debian/Fedora PPA and COPR release (BookiE ships Arch, Flatpak, AppImage and Debian).
