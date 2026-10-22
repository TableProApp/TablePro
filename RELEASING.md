# Releasing

Each app has its own runbook:

- The macOS app, its registry plugins, the static libraries and the manual iOS flow: [`apple/RELEASING.md`](apple/RELEASING.md), with the `release` skill (`.claude/skills/release/SKILL.md`).
- The Linux app: [`linux/docs/releasing.md`](linux/docs/releasing.md).

## Notes

Both apps turn their `changelog.d/` fragments into release notes with towncrier, pinned in `scripts/release/requirements.txt`. The venv both runbooks use, from the repository root:

```bash
python3 -m venv .venv && .venv/bin/pip install --require-hashes -r scripts/release/requirements.txt
```
