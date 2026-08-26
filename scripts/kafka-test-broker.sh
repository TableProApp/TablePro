#!/usr/bin/env bash
#
# kafka-test-broker.sh: start or stop the broker KafkaIntegrationTests runs against.
#
# The Kafka unit suites are pure logic and never open a socket. The integration suite drives
# the real driver end to end, so it needs a real broker, and it skips itself unless
# TABLEPRO_KAFKA_TEST_BOOTSTRAP names one.
#
# Usage:
#   scripts/kafka-test-broker.sh up      # start it and print the exports
#   scripts/kafka-test-broker.sh down    # remove it
#   scripts/kafka-test-broker.sh env     # print the exports for a broker already running
#
# Then:
#   eval "$(scripts/kafka-test-broker.sh env)"
#   .claude/skills/fix-issue/scripts/verify.sh test KafkaIntegrationTests
#
# Two listeners, not one. The CLI runs inside the container and must reach the broker at its
# INTERNAL advertised address, while the driver connects from the host to the EXTERNAL one. A
# single listener advertising "localhost" satisfies exactly one of those and fails the other
# with a node-assignment timeout.

set -euo pipefail

CONTAINER="${TABLEPRO_KAFKA_TEST_CONTAINER:-tp-kafka-it}"
PORT="${TABLEPRO_KAFKA_TEST_PORT:-19092}"
IMAGE="${TABLEPRO_KAFKA_TEST_IMAGE:-apache/kafka:latest}"

print_env() {
    echo "export TABLEPRO_KAFKA_TEST_BOOTSTRAP=127.0.0.1:${PORT}"
    echo "export TABLEPRO_KAFKA_TEST_CONTAINER=${CONTAINER}"
}

case "${1:-up}" in
up)
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running." >&2
        exit 1
    fi

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -p "${PORT}:${PORT}" \
        -e KAFKA_NODE_ID=1 \
        -e KAFKA_PROCESS_ROLES=broker,controller \
        -e "KAFKA_LISTENERS=INTERNAL://:9092,EXTERNAL://:${PORT},CONTROLLER://:9093" \
        -e "KAFKA_ADVERTISED_LISTENERS=INTERNAL://localhost:9092,EXTERNAL://localhost:${PORT}" \
        -e KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL \
        -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
        -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT \
        -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
        -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
        -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
        -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
        -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
        -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=false \
        "$IMAGE" >/dev/null

    printf 'Waiting for the broker' >&2
    for _ in $(seq 1 60); do
        if docker exec "$CONTAINER" /opt/kafka/bin/kafka-topics.sh \
            --bootstrap-server localhost:9092 --list >/dev/null 2>&1; then
            echo " ready." >&2
            print_env
            exit 0
        fi
        printf '.' >&2
        sleep 2
    done

    echo " gave up." >&2
    docker logs --tail 40 "$CONTAINER" >&2 || true
    exit 1
    ;;
down)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "Removed $CONTAINER." >&2
    ;;
env)
    print_env
    ;;
*)
    echo "Usage: $0 [up|down|env]" >&2
    exit 2
    ;;
esac
