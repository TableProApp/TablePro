# Evidence branch migration

Status: proposed; no GitHub `evidence` branch exists and no packet has been migrated. Existing evidence remains authoritative only for its recorded source snapshot and validated artifacts.

## Inventory snapshot

Inventory snapshot at GitHub `linux` commit `020ab94063550e13a053bec6743ae60be6a724a5` (2026-10-24): `docs/evidence/` has 2,263 tracked files in 293 packets, seven loose files and 58,965,996 bytes. `docs/archive/evidence/` has 1,237 tracked files in 264 packets and 5,630,132 bytes. The active tree has 198 manifest files, 164 using schema version 1; the validator reports 73 historical/source-drift findings. The archived tree has 245 manifest files, 219 using schema version 1; its validator reports 155 findings. A scan using the repository Markdown-link parser over maintained Markdown outside `docs/archive/` and `docs/evidence/` resolves 155 active packet directories; 137 contain manifests and 116 use schema version 1. Eighteen linked manifests have 31 findings: eight source differences, five incomplete source identities, one missing log, one log-digest mismatch, eight focused-selector/execution mismatches and eight focused-result-count mismatches. These concern provenance and artifact integrity; they do not independently establish either a current pass or a current product failure. The GitHub `evidence` branch does not exist and no packet has been migrated. Regenerate inventory, consumer search, privacy review and validation from the frozen migration source.

The two largest active packets, `built-head-2026-10-24` and `installed-arch-profile-2026-10-24`, total 44,042,982 bytes (74.7% of active evidence). Both have current in-tree citations. `built-head` combines multiple sources and run identities, so split and review it before migration. The [dated audit](../archive/evidence-branch-audit-2026-10-24.md) holds prior inventory snapshots, candidate-by-candidate external citation findings, redaction records and unresolved packet details. External links alone do not prove that a packet's contents are preserved; keep cited artifacts until validated immutable pointers and fresh-checkout retrieval exist.

## Boundary

Keep ADRs, test fixtures, acceptance criteria and concise source-pinned evidence summaries on `linux`. Move raw logs, profiles, screenshots and full run manifests gradually to a dedicated `evidence` branch. Small test fixtures remain in the code tree; evidence files that a test currently reads must first be replaced by dedicated test data and checked offline.

This keeps raw artifacts out of the current `linux` worktree and future `linux` commits; it does not reduce ordinary clone size. Existing `linux` history still references old artifact blobs, and default `git clone` fetches all branch heads, including `evidence` ([Git clone behavior](https://git-scm.com/docs/git-clone)). A single-branch clone avoids fetching the evidence-branch tip but still fetches blobs reachable from `linux` history. Clone-size reduction needs a shallow or partial-clone policy, or history rewriting; history rewriting is outside this proposal. The branch migration therefore targets a cleaner source tree and smaller working set, not recovery of disk space.

Do not move tests, fixtures consumed by tests, acceptance criteria or current known limitations. A moved artifact is historical proof, not proof that current Linux passed.

The first migration covers selected packets from `docs/evidence/`. `docs/archive/evidence/` is not part of the pilot, but remains in the eventual inventory: archival status alone does not make a packet disposable or exempt it from migration review. After the active-packet pilot, review archived packets separately by size, retained decision value, external citations, executable consumers and privacy. Apply the same pointer, retrieval and restore contract to any archived packet selected for migration; leave small or low-value packets in place when moving them adds no practical benefit.

## Storage and identity

Create `evidence` as an orphan branch containing only evidence packets; do not branch it from or merge it into `linux`. This keeps the evidence ref from inheriting the full application history. A normal clone may still fetch both refs; a code-only checkout can request `linux` alone, while its history still contains artifact blobs already committed there.

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

Before selecting packets, reconcile open pull requests that add or change evidence and freeze the exact Linux source commit. Regenerate the inventory and consumer search from that commit, and manually review each candidate packet for privacy until the scanner described below exists. The counts above are a dated baseline, not a migration manifest.

1. Triage validator warnings and identify which records support open issues, current limitations or architecture claims. Inventory each selected packet's links, executable consumers, source identity and privacy findings; split mixed-source bundles into source/run-scoped packets before migration.
2. Add offline pointer validation and a separate immutable-commit retrieval and restore check. Exercise retrieval and restoration against the pilot candidate from a clean checkout.
3. Copy the pilot's full manifest and artifacts to the evidence branch, verify every original digest and record the destination commit.
4. Replace the Linux manifest with its pointer, update direct artifact links and verify the retrieval check, doc links, evidence validation and the absence of raw files from the Linux tree.
5. Remove source copies only after those checks pass. Existing Linux history remains available; this does not rewrite history or reduce default clone size.

Do not migrate all packets in one change. Retain the original layout until the pilot passes retrieval and validation. Then select larger, low-warning active packets that have no test consumers and whose summaries still support a current issue or contract. Review archived packets in a later pass under the same criteria. Leave raw artifacts that add no current decision value in the normal archive unless their size justifies the migration cost.

## CI follow-up

Start with a manually dispatched publisher, then opt in individual completed runs. Identify each run by producer and run ID; numeric IDs are scoped to their CI service. Before download, verify the repository, allowlisted workflow and trusted workflow revision, event, ref, source and tested tree identities, successful conclusion, and exact artifact name. Initially accept only approved same-repository refs, not fork pull-request runs. Download artifacts as data and never execute them. Treat artifact content and filenames as untrusted: reject traversal, symlinks, duplicate paths, missing files and digest mismatches, and run the privacy scan before publication.

No reusable evidence-privacy scanner exists yet. Add one before enabling publication; test it with synthetic sensitive and clean fixtures, and make it fail closed without echoing matched values into logs. Cover credentials, private keys, connection strings, local usernames and paths, host or address data, and query or result content. Treat automated findings as review signals, not proof that an artifact is safe; require a human review of each packet before publication.

Protect the evidence branch against deletion and force-push. Use a trusted workflow revision with narrowly scoped contents-write permission. Never run code from the uploaded packet or expose write credentials to pull-request code. Serialize publishers, fetch the latest evidence head and create an ordinary fast-forward commit. Never force-push or overwrite an existing packet with different content. Re-publishing identical content is a no-op.

Add tests for rejected packets, immutable collision handling, concurrent publication, missing artifacts and exact source identity. Keep publication separate from test success: an upload failure cannot turn a failed test green, and an unavailable evidence service is reported explicitly.

Add a cheap Linux CI check for local summaries, manifest structure and immutable destination references. Verify remote artifact availability in the publisher and a scheduled audit, so every pull request does not depend on network retrieval.

## Acceptance

The first packet is retrievable by its pinned commit, its hashes match the recorded artifacts, all incoming links resolve, and a fresh checkout can validate it without the original worktree. A restore round trip returns the packet to its Linux path with the same manifest and artifact hashes while retaining the evidence-branch copy. Only then expand migration. The publisher requires its own code PR and workflow tests; this proposal does not claim that CI exists yet.
