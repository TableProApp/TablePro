# AGENTS.md

The project guide for this repository is `CLAUDE.md`. It is the single source of truth: principles, build and test commands, architecture, the invariants that have caused real bugs, and the mandatory rules for CHANGELOG, localization, docs, tests, lint, commit messages and writing style. It is too large for Codex to load automatically, so open it yourself before changing anything, in parts if needed, and read every section your change touches.

Path-scoped rules live in `.claude/rules/`. Each file's `paths:` frontmatter lists the files it governs. Read the matching file before editing any of them:

- `ai-mcp-security.md`: AI and MCP code, and the external API docs
- `data-sync-storage.md`: storage, sync and the database core
- `docs-authoring.md`: everything under `docs/`
- `plugin-system.md`: plugins, TableProPluginKit, `project.yml` and the plugin build scripts
- `ui-lifecycle.md`: views, view models and UI tests

Skills live in `.agents/skills/`. `fix-issue` is a link to `.claude/skills/fix-issue`, which Claude Code uses as well, so edit it there. Build, test and lint runs go through `.claude/skills/fix-issue/scripts/verify.sh`.
