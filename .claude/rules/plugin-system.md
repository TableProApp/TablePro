---
paths:
  - "Plugins/**/*"
  - "Packages/TableProCore/Sources/TableProPluginKit/**/*"
  - "project.yml"
  - ".github/workflows/build-plugin.yml"
  - "scripts/*plugin*"
---

# Plugin changes

Read `.agents/skills/tablepro-engineering/references/plugin-system.md`. Treat binary compatibility, open plugin types, bundled versus registry-only distribution, project regeneration, `AllPlugins`, and the ABI check as binding constraints.

This rule adds domain constraints. It does not pick your workflow: `AGENTS.md` decides whether you are in `$fix-issue` or `$tablepro-engineering`, and you never load both.
