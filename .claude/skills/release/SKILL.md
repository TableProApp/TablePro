---
name: release
description: >
  Cuts a TablePro macOS release: a beta, a stable or a patch. Picks fixes onto a release/X.Y line,
  curates the changelog fragments and the lead, decides whether a release is critical, opens the
  release PR, hands the maintainer the tag command, watches the run and forward-ports the release.
  Use whenever the user says "release", "cut a beta", "ship version", "tag a release", "promote the
  beta", "backport", or gives a version number ("/release 0.82.0", "/release 0.82.0-beta.2"). Not for
  the blog post, newsletter or X posts (the announce skill in TableProApp/web), and not for the iOS app.
---

# Release

`RELEASING.md` is the runbook and holds every command. This skill holds the judgment: each section is a decision, then names the runbook section that carries it out.

## 1. Ground rules

- Never push a tag, never create or delete a `release/*` branch, never push to `main` or `release/*`. The maintainer runs every block you hand over, in their own terminal, and tells you when it landed.
- A tag never moves. A fix after a tag is the next number.
- Release PRs and backport PRs go through the required checks like any other PR.

## 2. Read the state

Before any decision, gather:

- the tags, newest first: `git -c versionsort.suffix=-beta tag -l 'v*' --sort=-v:refname | head`;
- the live lines: `git ls-remote --heads origin 'release/*'`;
- open regressions: `gh issue list --label regression --state open`;
- open Dependabot alerts: `gh api --paginate 'repos/TableProApp/TablePro/dependabot/alerts?state=open&per_page=100' -q '.[].security_advisory.summary'`;
- main's push runs: `gh run list --branch main --event push --limit 10`, with macOS Tests, iOS and Package Tests and Release Build green on the commit you would cut;
- whether `main` has the last stable's `## [X.Y.Z]` heading. If not, the forward-port is missing and the next tag will refuse to build: do that first (section 9).

## 3. Decide what ships

- **beta.1 of X.Y**: `main` has features since the last X.Y.0.
- **beta.N**: the line has picks since its last beta.
- **Promote to X.Y.0**: the newest beta has no open `regression` issue.
- **Patch X.Y.Z**: the line has fixes only since its last stable.
- **X.0.0**: ask the maintainer.

Say which and why in one line, then wait for the maintainer to agree. Run: `RELEASING.md`, Cutting a beta, or Cutting a stable or patch.

## 4. Storage check

Before beta.1 and before a promotion, list the commits that touch user data since the previous stable: `git log --oneline v<prev>..<sha> --` followed by every `paths:` entry of `.claude/rules/data-sync-storage.md`. Read each one for a changed storage or sync format. Sparkle never downgrades, so a format the previous stable cannot read blocks the release until it is fixed on `main`. Run: `RELEASING.md`, Channels.

## 5. Critical or not

What counts as critical: `RELEASING.md`, Channels. Name the fix and the reason, and let the maintainer confirm. A critical stable gets ` [CRITICAL]` appended to its heading in the release PR. Run: `RELEASING.md`, Cutting a stable or patch.

## 6. Backport candidates

- Candidates: merged `main` PRs labeled `backport release/<X.Y>`, plus `fix` PRs for a bug the line has.
- Never a `feat`, and after `X.(Y+1).0` ships, only security or data-loss fixes.
- Already picked: `gh pr list --base release/<X.Y> --state merged --limit 200`. A pick's title keeps the original subject and its ` (#N)`.
- One fix per pick PR, from `backport/<PR>-<X.Y>`. A conflict that needs more than a mechanical resolution goes back to the maintainer.

Run: `RELEASING.md`, Branches.

## 7. Curate

- Compare what merged with the fragments: `gh pr list --state merged --base main --search "merged:>=<date of the last X.Y.0 cut>" --limit 1000 --json number,title,files`. A user-visible PR with no fragment needs one; a fragment that says more than its PR did needs rewording.
- Add or reword fragments through a PR to `main`, then pick it to the line. Entries change only through fragments; the lead and ` [CRITICAL]` are typed in the release PR.
- For X.Y.0, write the lead per `RELEASING.md`, Notes, in the reader's words. A release of fixes only can go without one.
- Check every fragment against `.claude/rules/changelog.md` and `scripts/check-banned-words.sh`.

Run: `RELEASING.md`, Notes, then Cutting a stable or patch.

## 8. Watch

- Follow the run with `gh run list --workflow release.yml --limit 3` and `gh run watch <id>`.
- Sort a failure into infrastructure (runner, network, notary service, an expired certificate) or code (a build, test or check the tag's commit fails). Infrastructure is a re-run; code is a fix on `main`, a pick, and the next number.
- Confirm the result from the source, not the cached site: `gh api -H 'Accept: application/vnd.github.raw' 'repos/TableProApp/TablePro/contents/appcast.xml?ref=gh-pages' | grep -c '<sparkle:shortVersionString><version></sparkle:shortVersionString>'` prints 1, and `gh release view v<version> --json assets -q '.assets | length'`.

Run: `RELEASING.md`, What a tag runs, and When a run fails.

## 9. After a stable or patch

- Open the forward-port PR to `main` (and to a newer open line), and the docs changelog PR.
- For an X.Y.0, name the `announce` skill in TableProApp/web as the next step.
- Before the next stable, check `retainFromPluginKit` against the license dashboard.

Run: `RELEASING.md`, Cutting a stable or patch, and Plugins.

## 10. Withdraw

Only when a build loses data, fails to launch or breaks connecting, and the fix is more than minutes away. The fix ships as the next number, critical when data was lost. Run: `RELEASING.md`, Withdrawing a release.
