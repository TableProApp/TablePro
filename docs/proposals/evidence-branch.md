# Evidence branch migration

Status: proposed. Existing evidence remains authoritative at its recorded source snapshot.

## Boundary

Keep ADRs, testing instructions, evidence summaries and manifests on `linux`. Move bulky screenshots, profiles and raw logs gradually to a dedicated `evidence` branch. This reduces active documentation and checkout size without separating contracts from their code.

Do not move tests, fixtures consumed by tests, acceptance criteria or current known limitations. A moved artifact is historical proof, not proof that current Linux passed.

## Storage and identity

Use append-only paths `runs/<source-commit>/<run-id>/`. Each packet records the full source commit, tested tree identity, command, environment, outcome, executed counts and SHA-256 digests for its files. Working-tree builds also record a patch digest; a base commit alone does not identify them.

Linux summaries link to the exact evidence commit and packet, rather than a mutable branch URL. Preserve original source and tool identities during migration. Never relabel an old run as current acceptance.

## First migration

1. Inventory tracked evidence files and their incoming links. Identify test consumers before choosing a packet.
2. Select one completed packet containing no secrets or production data. Keep its summary and manifest on Linux.
3. Copy its artifacts to the evidence branch, verify every digest, and record the destination commit.
4. Update links and the Linux manifest with that immutable destination. Validate the destination from a fresh checkout.
5. Remove source copies only after remote verification and link checks pass. Existing Git history remains available; this does not rewrite history or immediately shrink existing clones.

Do not migrate all packets in one change. Retain the original layout until the first packet has passed retrieval and validation.

## CI follow-up

Start with a manually dispatched publisher, then opt in individual completed runs. The publisher accepts a successful run identifier, downloads only that run’s artifacts and verifies the packet manifest before publishing. Treat artifact content and filenames as untrusted: reject traversal, symlinks, duplicate paths, missing files and digest mismatches.

Use a trusted workflow revision with narrowly scoped contents-write permission. Never run code from the uploaded packet or expose write credentials to pull-request code. Serialize publishers, fetch the latest evidence head and create an ordinary fast-forward commit. Never force-push or overwrite an existing packet with different content. Re-publishing identical content is a no-op.

Add tests for rejected packets, immutable collision handling, concurrent publication, missing artifacts and exact source identity. Keep publication separate from test success: an upload failure cannot turn a failed test green, and an unavailable evidence service is reported explicitly.

Add a cheap Linux CI check for local summaries, manifest structure and immutable destination references. Verify remote artifact availability in the publisher and a scheduled audit, so every pull request does not depend on network retrieval.

## Acceptance

The first packet is retrievable by its pinned commit, its hashes match the original, all incoming links resolve, and a fresh checkout can validate it without the original worktree. Only then expand migration. The publisher requires its own code PR and workflow tests; this proposal does not claim that CI exists yet.
