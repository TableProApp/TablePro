# 0022: Release notes come from merge commits, not a tracked changelog

- **Status**: Accepted
- **Date**: 2026-10-24
- **Supersedes**: the 2026-10-19 [changelog fragment evaluation](../archive/changelog-fragment-evaluation-2026-10-19.md), which kept a shared `CHANGELOG.md` and named its own revisit trigger.

## Context

Every pull request edited the `[Unreleased]` section of `CHANGELOG.md`. Between 2026-10-10 and 2026-10-24, 284 of 1,071 commits on `linux` touched that one file, and concurrent pull requests conflicted in it. The October 19 evaluation declined Towncrier fragments because conflict cost was unmeasured, and asked to reopen if conflicts recurred. They did.

Release notes are release output. A file that every change rewrites puts generated-looking content in the source tree and makes the aggregate train PRs of [ADR 0020](0020-aggregate-forgejo-trains.md) combine edits by hand.

## Decision

The release note of a change is a git trailer in its squash-merge commit message:

```
Release-Note: <Category>: <one line of user impact>
Release-Note: none
```

1. Categories are the Keep a Changelog 1.1.0 headings: Added, Changed, Deprecated, Removed, Fixed, Security. A change may carry several lines. `none` is explicit and cannot be combined with other lines. The wording rules of AGENTS.md are unchanged: user impact, no paths, type or function names, no `Fixed` for a defect introduced and fixed before release.
2. The pull request body carries the same lines, so a check can validate them before merge. The repository's squash-merge defaults are set to the PR title and the PR body (`squash_merge_commit_title=PR_TITLE`, `squash_merge_commit_message=PR_BODY`, changed on 2026-10-24 from `COMMIT_OR_PR_TITLE` and `COMMIT_MESSAGES`), so every merge carries the lines without anyone remembering to copy them. A merger who wants a shorter body can pass only the lines: `gh pr view N --json body -q .body | python3 scripts/release-notes.py trailers - > body.txt`, then `gh pr merge N --squash --body-file body.txt`. An aggregate train PR carries the lines of every constituent, and `scripts/check-forgejo-train.py` refuses to gate or merge a train whose body omits one.
3. `scripts/release-notes.py check` validates a body or message. `scripts/release-notes.py assemble --since <previous tag>` builds the release notes from the commit range, refuses a commit with no line unless told otherwise, and appends the pull request number from the squash subject. The output is a build artifact and the body of the GitHub Release.
4. `CHANGELOG.md` stops growing. Its `[Unreleased]` entries stay until the first release cut after this decision, and that release's notes are those entries plus the trailers after the adoption commit. In the same change as that cut, the whole file is first copied to `docs/archive/changelog-through-<version>-<date>.md` unchanged, then `CHANGELOG.md` is removed and its remaining links and script references are repointed. The 0.1.x record is already archived.

## Rationale

The squash commit is the unit that reaches `linux` and the one thing every merge path shares, including trains. It cannot conflict, adds no per-PR file, and keeps the note next to the change it describes. A required line, even `none`, replaces the unenforced habit of remembering to edit the changelog.

## Consequences

Accepted:

- The whole PR description becomes the squash commit body, so the description must be written to stand in history. The check on the pull request body is what catches a missing line.
- A merger who overrides the default message in the GitHub merge box can drop the lines; the assembler reports such a commit as missing.
- Notes cannot be corrected by a later pull request; a wrong one is fixed in the release draft before publishing.
- AGENTS.md's "single-line subject and no body" no longer describes squash commits, whose body is the PR description. Branch commits keep the single-line rule.

Gained:

- No more changelog merge conflicts and no release-note content in source review diffs.
- A release can be previewed from any range with one command.

## Alternatives considered

- **Keep `CHANGELOG.md` as it is.** Rejected: the conflict rate above.
- **Towncrier or other fragment files (`changelog.d/<pr>.md`).** Rejected: removes conflicts but still adds a file to the repository for every change, which is the content this decision takes out of the tree, and adds a pinned generator with fragment naming rules.
- **Derive notes from Conventional Commit subjects alone.** Rejected: subjects describe the change to developers. AGENTS.md requires user-impact wording, and many commits (CI, tests, refactors) have no user impact.
- **A PR-body block read through the GitHub API at release time.** Rejected as the source of record: it needs network access and tokens at release time, and the text can be edited after merge. The same lines are in the PR body for validation only.
- **Leave the squash-message setting alone and rely on the merger to copy the lines.** Rejected: the rule would live only in AGENTS.md.
- **GitHub's generated release notes.** Rejected: they list titles and authors, not user impact.

## Implementation status

Landed: the trailer grammar, `check`, `trailers` and `assemble` in `scripts/release-notes.py` with tests, the PR template line, and the documentation. Not landed: a required pull request check and the `release.yml` step that calls `assemble` instead of reading `CHANGELOG.md`. Both edit workflows and wait for the app-side session. Until then `release.yml` still reads `CHANGELOG.md`, so the first cut must reconcile as described in point 4.
