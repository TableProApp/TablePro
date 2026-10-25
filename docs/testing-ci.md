# CI tests and gates

Part of [testing](testing.md), which holds the test tiers, runner and fixtures.

## CI

Where each check runs is owned by [CI tiers in the validation playbook](validation-playbook.md#ci-tiers). GitHub runs the cheap tier on pull requests; Forgejo runs the merge tier on branch pushes. Documentation-only changes skip the heavy path. Do not treat a skipped GitHub merge-tier job as a pass.

Headless driver, TLS, PostgreSQL release and dump, and socket/SSH jobs start after guards, Clippy, unit and sandbox pass. They do not wait for widget tests. Widgets remain a required job, and GUI jobs retain their widget dependencies. Every tier must still pass for merge acceptance.

Every job in the Forgejo merge workflow has an explicit timeout. Checkout credentials are supplied to Git as a host-scoped HTTP authorization header for the clone step; they are not embedded in the clone URL or saved in the checkout's `origin` URL. This reduces accidental exposure through process arguments and `.git/config`, but it does not isolate workflow code. `any-host` runners execute branch code on shared hosts with Docker access, so only trusted branch writers may trigger these workflows until a dedicated isolated runner is deployed and accepted. See the [runner maintenance and isolation proposal](proposals/runner-maintenance-and-isolation.md) for the pending deployment work.

### Shared native GTK artifact

On Forgejo merge-workflow runs, `gtk-build` compiles one `tablepro-app` binary for the exact source commit. The `e2e`, `gtk` and `gtk-server` jobs download and verify that artifact instead of compiling their own copy. The manifest records the source commit, SHA-256, architecture, `ci` profile, default app features and GTK, GLib, libadwaita and GtkSourceView versions. A consumer must match the source, architecture, profile and features, and provide the same toolkit major versions at versions at least as new as the build. The distro-floor Debian package has a separate artifact and acceptance path.

Artifact reuse reduces repeated builds but does not by itself establish the time saved. Compare queue, build and total workflow durations across equivalent Forgejo runs before claiming a gate-time improvement; keep every test job and fixture isolated.

The `ubuntu2604-canary` runner executes the headless multi-database TLS fixture job, which builds and starts many containers. Its GTK, libadwaita and GtkSourceView versions are below the supported floor, so GTK jobs stay on eligible hosts.

### Gating several pull requests at once

`scripts/forgejo-train.sh BRANCH BRANCH...` requires a clean current checkout, fetches named branches from the remote that tracks `github.com/cozyGarage/BookiE`, and merges them onto that remote's `linux` tip in order. It stops at the first conflict and restores the original checkout on exit; it creates no worktree. Set `FORGEJO_TRAIN_REMOTE` to choose a remote by name. `FORGEJO_TRAIN_DRY=1` builds the train without queueing Forgejo. This helper does not replace the accepted aggregate PR checks below. `CHANGELOG.md` and the PostgreSQL `connection_paths.rs` registry merge by union (`.gitattributes`), because every pull request appends to them and they were the usual cause of conflicts. A union merge keeps both sides in arbitrary order, so two branches that each add a module to the registry can combine into a tree that fails `cargo fmt --check` although each passes alone. The train therefore runs `cargo fmt` and commits the result when only union-merged files changed. When any other file changes, the train names the file and stops rather than formatting it away and gating a tree no pull request contains.

### Aggregate train acceptance

[ADR 0020](decisions/0020-aggregate-forgejo-trains.md) defines the accepted merge unit. The queue owner prepares a small batch in the current clean checkout, starting a new train branch at the freshly fetched GitHub `linux` SHA. Merge each exact constituent head with a separate `--no-ff` merge in the recorded order. Stop on conflicts; do not silently skip an input. Retain necessary reviews and each PR's GitHub checks. Resolve no behavior changes merely to make a train pass.

Commit `ci/forgejo-train.json` on that branch with this shape, replacing the SHA placeholders with full commit IDs:

```json
{"version": 1, "base": "BASE_SHA", "members": [{"number": 1197, "sha": "FIRST_HEAD_SHA"}, {"number": 1201, "sha": "SECOND_HEAD_SHA"}]}
```

Open one aggregate PR against `linux`, listing the constituents and any train-owned changes. Its body also carries every constituent's `Release-Note:` lines (or a single `Release-Note: none` when none has one), because the squash commit body is the PR body ([ADR 0022](decisions/0022-release-notes-from-merge-commits.md)); `check-forgejo-train.py` refuses a train whose body drops one. Its GitHub checks must pass too. Use the following checks with the actual train PR number and Forgejo run ID:

```bash
python3 scripts/check-forgejo-train.py TRAIN_PR --phase gate
train_head="$(git rev-parse HEAD)"
bash scripts/forgejo-gate.sh "$train_head" "train/$train_head"
python3 scripts/check-forgejo-train.py TRAIN_PR --phase merge --run RUN_ID
gh pr merge TRAIN_PR --squash --match-head-commit "$train_head"
python3 scripts/check-forgejo-train.py TRAIN_PR --phase merged --run RUN_ID
```

The verifier reads the committed manifest from the aggregate head, checks the exact integration order, rejects moved constituents or base, requires the ordinary GitHub checks and verifies successful `ci.yml` evidence at that head. `--remote` selects the GitHub remote when it is not named `origin`. Reference CodeQL and Sonar scans retain their existing non-gating status. Required skipped checks never count as passes.

Run the merge check immediately before merging and coordinate base pushes with the queue owner. A changed base/head requires a new train. After the merged-tree comparison passes, close each constituent PR as included with a link to the aggregate PR. Close only satisfied issues, sync Forgejo's `linux` through the serialized gate script and remove only clean, completed worktrees. A tree mismatch stops further acceptance for investigation. A failed train approves no subset; split it and gate the new heads for diagnosis.

### Reading a red run

`scripts/classify-ci-failure.py --run RUN_ID` (or `--log FILE`) tags each failed job from its log. It reads the Forgejo endpoint and token from the same configuration as `scripts/forgejo-gate.sh`.

| Tag | Meaning | What to do |
|---|---|---|
| `infra` | Image pull or fixture start timeout, compiler crash, rate limit, runner volume path, a job log that ends without a result (runner or Forgejo connection lost) | Retry before reading code |
| `gui-timing` | The window did not appear | Retry once |
| `gui` | A GUI assertion failed | Ambiguous: a missing accessible node can be load or a real regression. Rerun once; if the same scenario fails again on a quiet runner, treat it as code |
| `code` | Test panic, compile or lint error, application crash, startup layout abort | Read the log and fix |

The tag is advice only and never changes a result. A new infrastructure signature goes in the `SIGNATURES` table with a test in `scripts/tests/test_classify_ci_failure.py`.
