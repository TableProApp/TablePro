---
name: release
description: >
  Cuts a TablePro macOS release: a beta, a stable or a patch. Reads the release state, decides with
  the maintainer what ships and whether it is critical, runs the storage check, picks fixes onto a
  release/X.Y line, curates the notes in the release PR, tags, watches the run and forward-ports the
  release. Use whenever the user says "release", "cut a beta", "ship version", "tag a release",
  "promote the beta", "backport", or gives a version number ("/release 0.83.0", "/release
  0.83.0-beta.2"). Not for the blog post, newsletter or X posts (the announce skill in
  TableProApp/web), and not for the iOS app.
---

# Release

`apple/RELEASING.md` holds every command and rule. This skill is the order of decisions.

When the maintainer says to release, you run every release command yourself: picks, the release PR, creating `release/X.Y`, pushing the tag, the forward-port and re-runs. The maintainer decides what ships and whether it is critical: say which and why in one line, then wait for a yes.

## 1. Read the state

```bash
git fetch origin --tags
git -c versionsort.suffix=-beta tag -l 'v*' --sort=-v:refname | head
git ls-remote --heads origin 'release/*'
gh issue list --label regression --state open
gh release view vX.Y.0-beta.N --json publishedAt -q .publishedAt
gh run list --workflow ci.yml --branch main --event push --limit 5
gh run list --workflow release-build.yml --branch main --limit 3
gh api --paginate 'repos/TableProApp/TablePro/dependabot/alerts?state=open&per_page=100' -q '.[].security_advisory.summary'
```

- `git grep -c '^## \[X.Y.Z\]' origin/main -- apple/CHANGELOG.md` finds the last stable's heading. Without it, the forward-port goes first.
- A red Release Build is no gate, but the tag's `app` or `plugins` job likely fails the same way.

## 2. Decide what ships

Apply `apple/RELEASING.md`, Train: a promotion, a beta.1, a beta.N for a line with new picks, a patch past the bar in Branches, or nothing. Ask about an X.0.0.

- Pick candidates: `fix` PRs merged to `main` since the line was cut, for a bug the line has: `gh pr list --state merged --base main --search "merged:>=<cut date>" --limit 1000 --json number,title,files`.
- Already picked: `gh pr list --base release/X.Y --state merged --limit 200`.
- A pick conflict that needs more than a mechanical fix goes back to the maintainer.

## 3. Storage check

Before beta.1 and X.Y.0, run `apple/RELEASING.md`, Storage check, and read each commit it lists. A format the previous stable cannot read blocks the release.

## 4. Critical

For a stable or patch, name the fix and the reason, and ask. Only a security fix or data loss counts. An open Dependabot alert on a shipped dependency is a candidate.

## 5. Curate in the release PR

- Every user-visible PR in the release has a fragment, and no fragment says more than its PR did (`.claude/rules/changelog.md`).
- On `prep/vX.Y.Z`, add or reword fragments before `notes.py assemble`. For an X.Y.0, write the lead in the reader's words; a release of fixes only can go without one.
- A beta's notes are the fragments as they stand: `.venv/bin/python apple/scripts/release/notes.py body X.Y.0-beta.N` on the line head previews them.

## 6. Follow RELEASING

Run `apple/RELEASING.md`: Cutting a beta, or Cutting a stable or patch, then Forward-port. On a failure, When a run fails or Withdrawing a release.

- Watch the tag's run: `gh run list --workflow release.yml --limit 3`, then `gh run watch <id> --exit-status`.
- After an X.Y.0, the `announce` skill in TableProApp/web is next.
