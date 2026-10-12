#!/usr/bin/env bash
#
# kafka-test-broker.sh: start or stop the broker KafkaIntegrationTests runs against.
#
# The Kafka unit suites are pure logic and never open a socket. The integration suite drives
# the real driver end to end, so it needs a real broker, and it skips itself unless one
# answers on TABLEPRO_KAFKA_TEST_BOOTSTRAP.
#
# Usage:
#   scripts/kafka-test-broker.sh up [--brokers N]   # start it and print the exports
#   scripts/kafka-test-broker.sh down               # remove it
#   scripts/kafka-test-broker.sh env                # print the exports for one already running
#
# Then:
#   eval "$(scripts/kafka-test-broker.sh env)"
#   .claude/skills/fix-issue/scripts/verify.sh test KafkaIntegrationTests
#
# Two listeners, not one. The CLI runs inside a container and must reach the cluster at its
# INTERNAL advertised address, while the driver connects from the host to the EXTERNAL one. A
# single listener advertising "localhost" satisfies exactly one of those and fails the other
# with a node-assignment timeout.
#
# --brokers takes a count because one broker cannot reproduce a routing bug. On a single-node
# cluster that node leads every partition and coordinates every group, so a client that sends
# every request to whichever broker it happens to hold is indistinguishable from a correct one.
# That is why the suite passed for the whole life of issue #2993, and why three is the default
# the routing tests ask for: enough that a topic's partitions land on brokers the client did not
# connect to.

set -euo pipefail

CONTAINER="${TABLEPRO_KAFKA_TEST_CONTAINER:-tp-kafka-it}"
PORT="${TABLEPRO_KAFKA_TEST_PORT:-19092}"
IMAGE="${TABLEPRO_KAFKA_TEST_IMAGE:-apache/kafka:latest}"
NETWORK="${CONTAINER}-net"
# Fixed so every node of one cluster formats the same storage id. Generated ids differ per
# container and the nodes then refuse to form a quorum.
CLUSTER_ID="${TABLEPRO_KAFKA_TEST_CLUSTER_ID:-5L6g3nShT-eMCtK--X86sw}"

BROKERS=1
ACTION="${1:-up}"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
    --brokers)
        BROKERS="${2:-1}"
        shift 2
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
    esac
done

if ! [ "$BROKERS" -ge 1 ] 2>/dev/null; then
    echo "--brokers needs a count of 1 or more." >&2
    exit 2
fi

container_name() {
    if [ "$1" -eq 1 ]; then echo "$CONTAINER"; else echo "${CONTAINER}-$1"; fi
}

external_port() {
    echo $((PORT + $1 - 1))
}

print_env() {
    echo "export TABLEPRO_KAFKA_TEST_BOOTSTRAP=127.0.0.1:${PORT}"
    echo "export TABLEPRO_KAFKA_TEST_CONTAINER=${CONTAINER}"
}

remove_all() {
    # A bounded sweep rather than a name glob, so this never reaches a container the script
    # did not start.
    for node in $(seq 1 16); do
        docker rm -f "$(container_name "$node")" >/dev/null 2>&1 || true
    done
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

case "$ACTION" in
up)
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running." >&2
        exit 1
    fi

    remove_all
    docker network create "$NETWORK" >/dev/null 2>&1 || true

    voters=""
    for node in $(seq 1 "$BROKERS"); do
        voters="${voters:+$voters,}${node}@$(container_name "$node"):9093"
    done

    for node in $(seq 1 "$BROKERS"); do
        name="$(container_name "$node")"
        port="$(external_port "$node")"
        docker run -d --name "$name" --network "$NETWORK" -p "${port}:${port}" \
            -e CLUSTER_ID="$CLUSTER_ID" \
            -e KAFKA_NODE_ID="$node" \
            -e KAFKA_PROCESS_ROLES=broker,controller \
            -e "KAFKA_LISTENERS=INTERNAL://:9092,EXTERNAL://:${port},CONTROLLER://:9093" \
            -e "KAFKA_ADVERTISED_LISTENERS=INTERNAL://${name}:9092,EXTERNAL://127.0.0.1:${port}" \
            -e KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL \
            -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
            -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT \
            -e "KAFKA_CONTROLLER_QUORUM_VOTERS=$voters" \
            -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR="$BROKERS" \
            -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR="$BROKERS" \
            -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
            -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
            -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=false \
            "$IMAGE" >/dev/null
    done

    printf 'Waiting for %s broker(s)' "$BROKERS" >&2
    for _ in $(seq 1 90); do
        ready=$(docker exec "$CONTAINER" /opt/kafka/bin/kafka-broker-api-versions.sh \
            --bootstrap-server localhost:9092 2>/dev/null | grep -c 'id:' || true)
        if [ "${ready:-0}" -ge "$BROKERS" ]; then
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
    remove_all
    echo "Removed $CONTAINER." >&2
    ;;
env)
    print_env
    ;;
*)
    echo "Usage: $0 [up [--brokers N]|down|env]" >&2
    exit 2
    ;;
esac
