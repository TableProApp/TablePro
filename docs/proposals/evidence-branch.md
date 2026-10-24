# Evidence branch migration

Status: proposed; no GitHub `evidence` branch exists and no packet has been migrated. Existing evidence remains authoritative only for its recorded source snapshot and validated artifacts.

## Inventory snapshot

The inventory began at Linux source `30e9267221de7c3c75d41a473164f569a9475cba`: 3,422 tracked files in 552 packet directories, six loose files and 22,122,845 bytes. The evidence audit moved 202 historical packets to the archive and checked in-repository consumers, external GitHub citations, manifests and redaction records. The dated [October 24 audit snapshot](../archive/evidence-branch-audit-2026-10-24.md) records the candidate-by-candidate findings and exclusions.

At the audit worktree snapshot based on Linux `5b9619e6e` (including merged PR #1568 and the later installed-package evidence update), the tracked working tree has 2,243 files in 290 active packets, seven loose files and 47,525,534 bytes under `docs/evidence/`; `docs/archive/evidence/` has 1,237 files in 264 packets and 5,630,132 bytes. These figures exclude three ignored local logs. This snapshot is not a migration manifest. The installed-package JSON omits the source commit, but its archive and binary hashes match the extracted package recorded against earlier PR commit `748c75c0f904e6c53f41236b1a3d36668bd079b5`. That commit appears in PR #1568 history; the cache implementation and its performance tests match the final merged tree. The archive hash differs from the published 0.2.0 Arch asset, so the capture supports the candidate package and cache path, not final UI or release acceptance. Regenerate inventory, consumer search and privacy scan at the frozen migration source.

The active validator checks 164 schema-version-1 manifests and reports 70 historical/source-drift findings. The archived validator checks 219 and reports 155. These warnings describe historical proof gaps, not current product-test failures. The `83674cf6` run log remains byte-identical to its previously redacted form, with original and derivative hashes recorded. The B7 run's missing log and unavailable source revision remain explicitly unverified. The audit snapshot contains details on external citations, restored logs and packet-level provenance.

## Boundary

Keep ADRs, test fixtures, acceptance criteria and concise source-pinned evidence summaries on `linux`. Move raw logs, profiles, screenshots and full run manifests gradually to a dedicated `evidence` branch. Small test fixtures remain in the code tree; evidence files that a test currently reads must first be replaced by dedicated test data and checked offline.

This keeps raw artifacts out of the current `linux` worktree and future `linux` commits; it does not reduce ordinary clone size. Existing `linux` history still references old artifact blobs, and default `git clone` fetches all branch heads, including `evidence` ([Git clone behavior](https://git-scm.com/docs/git-clone)). A single-branch clone avoids fetching the evidence-branch tip but still fetches blobs reachable from `linux` history. Clone-size reduction needs a shallow or partial-clone policy, or history rewriting; history rewriting is outside this proposal. The branch migration therefore targets a cleaner source tree and smaller working set, not recovery of disk space.

Do not move tests, fixtures consumed by tests, acceptance criteria or current known limitations. A moved artifact is historical proof, not proof that current Linux passed.

## Storage and identity

Use append-only paths `runs/<source-commit>/<producer>/<run-id>/`, where producer distinguishes GitHub Actions, Forgejo Actions and local runs. This prevents unrelated systems' run identifiers from colliding. Each packet records the full source commit, producer and run identifier, tested tree identity, command, environment, outcome, executed counts and SHA-256 digests for its files. The current `run-test-layer.py` report hashes `git diff HEAD` and records `git status`; that digest omits untracked file contents. Until [#1541](https://github.com/cozyGarage/BookiE/issues/1541) is resolved, only claim complete tree provenance for clean runs. Dirty-tree runs must either be refused or identify all tested untracked source bytes as well as tracked changes.

Linux summaries link to the exact evidence commit and packet, rather than a mutable branch URL. Keep the full run manifest beside its artifacts on the evidence branch; retain only the summary and an immutable pointer in the Linux tree. Preserve original source and tool identities during migration. Never relabel an old run as current acceptance.

## Pointer and validation contract

Keep a small pointer at each migrated packet's existing Linux path so current index links and historical citations still resolve. The pointer records the original source commit and tree identity, the evidence branch commit and packet path, and the SHA-256 of the full manifest. The full manifest and artifacts stay together on the evidence branch. Preserve artifact digests during migration. If an artifact is redacted, the manifest records the digest of the current derived bytes and a redaction record preserves the original and derived digests; never present the derived bytes as the original.

Keep the main documentation page a navigation map. The dated October 2026 engineering-record catalog now lives in `docs/archive/engineering-review-records-2026-10.md`, with one link from the map; keep it there during packet migration and update any link whose Linux summary moves. Do not duplicate every evidence link in the current map and an evidence catalog.

Update references that link directly to a moved log or screenshot to the immutable evidence commit. Do not leave links to mutable branch-head URLs. Before removing a source artifact, search maintained and archived Markdown, evidence manifests and inventories, redaction records, scripts, test manifests, CI configuration, Sonar and CodeQL configuration, and path-check exemptions for consumers. Search GitHub issue and pull-request bodies and comments for cited paths as well. Keep an externally cited path available through a pointer or leave that artifact in place until a replacement is validated. Replace any test-consumed evidence with a small checked-in fixture before moving it.

The Linux validator must recognize pointers and validate their local structure without fetching the evidence branch. A separate retrieval check verifies the immutable remote commit, packet path and full-manifest digest from a fresh checkout. Ordinary preflight and offline tests remain network-independent. Strict harness inputs stay local until replaced by dedicated fixtures. After migration, check that the Linux tree contains no moved raw artifact and that the remote packet still passes digest verification.

Support restoring a packet to `linux` as well as retrieving it for inspection. Restore only from the pointer's pinned evidence commit, verify the manifest and every artifact digest, and refuse to overwrite existing files. Replace the pointer with the restored packet at its original path and keep the evidence-branch copy. A restored redacted derivative has its own digest and provenance; restoration must not claim it recreates the original bytes.

The first retrieval pilot candidate is `postgres-domain-enum-filter-results-2026-10-03`: its 2,009-byte packet has a reachable source commit, its current manifest validates without warnings, and the active value index links to it. It has no test consumer. This is intentionally a small workflow pilot, not a storage-saving migration. Do not move it until pointer validation and fresh-checkout retrieval exist.

## First migration

Before selecting packets, reconcile open pull requests that add or change evidence and freeze the exact Linux source commit. Regenerate the inventory, consumer search and privacy scan from that commit; the counts above are a dated baseline, not a migration manifest.

1. Triage validator warnings and identify which records support open issues, current limitations or architecture claims. Inventory each selected packet's links, executable consumers, source identity and privacy findings.
2. Add offline pointer validation and a separate immutable-commit retrieval and restore check. Exercise retrieval and restoration against the pilot candidate from a clean checkout.
3. Copy the pilot's full manifest and artifacts to the evidence branch, verify every original digest and record the destination commit.
4. Replace the Linux manifest with its pointer, update direct artifact links and verify the retrieval check, doc links, evidence validation and the absence of raw files from the Linux tree.
5. Remove source copies only after those checks pass. Existing Linux history remains available; this does not rewrite history or reduce default clone size.

Do not migrate all packets in one change. Retain the original layout until the pilot passes retrieval and validation. Then select larger, low-warning packets that have no test consumers and whose summaries still support a current issue or contract. Leave raw artifacts that add no current decision value in the normal archive unless their size justifies the migration cost.

## CI follow-up

Start with a manually dispatched publisher, then opt in individual completed runs. The publisher accepts a successful run identifier, downloads only that run’s artifacts and verifies the packet manifest before publishing. Treat artifact content and filenames as untrusted: reject traversal, symlinks, duplicate paths, missing files and digest mismatches.

Protect the evidence branch against deletion and force-push. Use a trusted workflow revision with narrowly scoped contents-write permission. Never run code from the uploaded packet or expose write credentials to pull-request code. Serialize publishers, fetch the latest evidence head and create an ordinary fast-forward commit. Never force-push or overwrite an existing packet with different content. Re-publishing identical content is a no-op.

Add tests for rejected packets, immutable collision handling, concurrent publication, missing artifacts and exact source identity. Keep publication separate from test success: an upload failure cannot turn a failed test green, and an unavailable evidence service is reported explicitly.

Add a cheap Linux CI check for local summaries, manifest structure and immutable destination references. Verify remote artifact availability in the publisher and a scheduled audit, so every pull request does not depend on network retrieval.

## Acceptance

The first packet is retrievable by its pinned commit, its hashes match the recorded artifacts, all incoming links resolve, and a fresh checkout can validate it without the original worktree. A restore round trip returns the packet to its Linux path with the same manifest and artifact hashes while retaining the evidence-branch copy. Only then expand migration. The publisher requires its own code PR and workflow tests; this proposal does not claim that CI exists yet.
