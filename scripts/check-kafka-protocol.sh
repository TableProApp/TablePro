#!/usr/bin/env bash
#
# check-kafka-protocol.sh: re-verify the Kafka wire-format assumptions the Swift codec
# hard-codes, against a real broker.
#
# Plugins/KafkaDriverPlugin/ speaks Kafka's binary protocol directly, and four of its
# encoding decisions are not derivable from the surrounding format. Each one fails the same
# way when it is wrong: the broker consumes what it can and closes the socket, with no error
# response and nothing in any log. That is the worst possible failure signature, so these
# facts are checked against a live broker rather than trusted.
#
# The same shape as scripts/check-redis-command-routing.sh: a hand-written table in Swift
# that has to agree with a real server and that nothing at runtime can catch.
#
# Usage:
#   scripts/check-kafka-protocol.sh [host] [port]     # default 127.0.0.1 9092
#
# To bring a broker up first:
#   docker run -d --name tp-kafka -p 9092:9092 \
#     -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
#     -e KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 \
#     -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
#     -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
#     -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
#     -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
#     -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
#     -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
#     -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
#     apache/kafka:latest

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-9092}"

exec python3 "$(dirname "$0")/ci/kafka-protocol-probe.py" "$HOST" "$PORT"
