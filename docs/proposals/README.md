# Open proposals

Proposals record designs that have not become accepted decisions. They do not set release scope. Accepted constraints live in [ADRs](../decisions/README.md); selected work and status live in [Project #3](https://github.com/users/cozyGarage/projects/3) and the [backlog](../backlog.md). Recheck each linked issue and source before acting.

| Proposal | Current boundary |
|---|---|
| [CI build speed](ci-build-speed.md) | UX-owned, measurement-gated; no workflow split is selected. |
| [Evidence branch migration](evidence-branch.md) | Proposed; no branch or packet has been migrated. Retrieval and restore must pass the pilot first. |
| [Import into existing rows](import-existing-rows.md) | Unscheduled candidate; no behavior is implemented. |
| [Statement effects and joined verdict](policy-effects-and-verdict.md) | Behavioral defects are closed; only the post-0.2.0 single-AST-walk consolidation remains in #571. |
| [Runner maintenance and isolation](runner-maintenance-and-isolation.md) | Repository safeguards exist; deployment and isolated-runner acceptance remain unverified under #573. |
| [SSH jump-chain editor](ui-1b-ssh-jump-chain-editor.md) | Backend support is merged; form editing and installed acceptance remain under #548. |
| [Local dependency patches](upstream-patches.md) | Removal criteria and patch provenance; verify current upstream releases before changing vendored code. |

The completed workstation reuse pilot and its dated execution plan are in the [archive](../archive/workstation-test-reuse-2026-10-20.md). Use the current [validation playbook](../validation-playbook.md) for test tiers and commands.
