# Capability specs

Behaviour by capability, extracted from the code that already ships. The ledger and sprint stay the work tracker. A spec describes what is true now: when it and the code disagree, check the code and fix the spec. It never overrides [AGENTS.md](../AGENTS.md).

| Capability | Serves | Implementation | Specification |
|---|---|---|---|
| [database-workspace](database-workspace/spec.md) | `Local DBA`, developer | implementation tracked by [#1349](https://github.com/cozyGarage/BookiE/issues/1349) | draft, needs review |
| [governed-sql](governed-sql/spec.md) | `Local DBA`, `MCP operator` | in use; acceptance tracked separately | draft, needs review |
| [ssh-transport](ssh-transport/spec.md) | `Local DBA` | in use; route acceptance tracked separately | draft, needs review |
| [secret-storage](secret-storage/spec.md) | `Local DBA`, `MCP operator` | shipped under ADR 0004 | draft, needs review |
