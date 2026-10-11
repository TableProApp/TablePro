#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
for tool in docker ssh ssh-agent ssh-add ssh-keygen; do
  command -v "$tool" >/dev/null
done
cargo test --locked -p tablepro-ssh --test agent_auth --test openssh_session \
  -- --include-ignored --test-threads=1
