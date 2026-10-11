#!/usr/bin/env bash
set -euo pipefail
if [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
  echo "Docker Hub credentials not set; pulling anonymously"
  exit 0
fi
printf '%s' "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USERNAME" --password-stdin >/dev/null
echo "Docker Hub login ok"
