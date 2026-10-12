#!/usr/bin/env bash
#
# dynamodb-test-local.sh: start or stop the DynamoDB Local that DynamoDBLocalIntegrationTests runs
# against.
#
# The DynamoDB unit suites are pure logic and never open a socket. The integration suite drives the
# real driver end to end, so it needs a DynamoDB, and it skips itself unless one answers on
# 127.0.0.1:18000. It creates its own uniquely named tables and deletes them afterwards.
#
# Usage:
#   scripts/dynamodb-test-local.sh up     # start it (in memory, shared database)
#   scripts/dynamodb-test-local.sh down   # remove it
#
# Then:
#   .claude/skills/fix-issue/scripts/verify.sh test DynamoDBLocalIntegrationTests
#
# DynamoDB Local is not the service. It updates ItemCount live where AWS refreshes it about every
# six hours, it has no point-in-time recovery or tags, and it accepts any credentials, so a green
# run here says nothing about authentication, throttling or those settings.

set -euo pipefail

CONTAINER="${TABLEPRO_DYNAMODB_TEST_CONTAINER:-tp-dynamodb-it}"
PORT="${TABLEPRO_DYNAMODB_TEST_PORT:-18000}"
IMAGE="${TABLEPRO_DYNAMODB_TEST_IMAGE:-amazon/dynamodb-local:latest}"
ACTION="${1:-up}"

case "$ACTION" in
up)
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "$CONTAINER is already running on port $PORT."
        exit 0
    fi
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -p "127.0.0.1:${PORT}:8000" "$IMAGE" \
        -jar DynamoDBLocal.jar -inMemory -sharedDb > /dev/null
    for _ in $(seq 1 30); do
        if curl -s -o /dev/null "http://127.0.0.1:${PORT}"; then
            echo "DynamoDB Local is answering on 127.0.0.1:${PORT}."
            exit 0
        fi
        sleep 1
    done
    echo "DynamoDB Local did not answer on 127.0.0.1:${PORT} within 30 seconds." >&2
    exit 1
    ;;
down)
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
    echo "Removed $CONTAINER."
    ;;
*)
    echo "Usage: $0 up|down" >&2
    exit 2
    ;;
esac
