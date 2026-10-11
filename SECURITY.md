# Security

**Reporting a vulnerability.** Use GitHub private vulnerability reporting: https://github.com/cozyGarage/BookiE/security/advisories/new

Do not open a public issue for anything exploitable. Do not attach secrets, connection files, tokens or unmasked query results. Expect an acknowledgment within 3 business days.

**Scope.** This repository and the Linux packages it builds (`bookie`, `bookie-agentd`, and the `tablepro` aliases). Third-party engines and crates go to their own maintainers.

**No secrets in this repo.** Passwords, tokens and SSH secrets belong in Secret Service through `tablepro-storage`. Dependency review uses `deny.toml` and `cargo deny`. In-code invariants stay in [AGENTS.md](AGENTS.md).
