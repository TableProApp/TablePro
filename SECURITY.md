# Security

**Reporting a vulnerability.** Use GitHub private vulnerability reporting: https://github.com/cozyGarage/BookiE/security/advisories/new

Do not open a public issue for anything exploitable. Do not attach secrets, connection files, tokens or unmasked query results. Expect an acknowledgment within 3 business days.

**Scope.** This repository and the Linux packages it builds (`bookie`, `bookie-agentd`, and the `tablepro` aliases). Third-party engines and crates go to their own maintainers.

**No secrets in this repo.** Database passwords and SSH secrets belong in Secret Service through `tablepro-storage`. GUI-issued MCP token plaintext is returned once and keyring storage is attempted; issuance still succeeds if that save fails. `bookie-agentd` emits a newly issued token once to stdout or an explicitly selected owner-only file. Do not put secrets in connection JSON, command-line arguments, traces, errors or audit fields. Dependency review uses `deny.toml` and `cargo deny`. In-code invariants stay in [AGENTS.md](AGENTS.md).
