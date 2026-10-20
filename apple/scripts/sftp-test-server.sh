#!/usr/bin/env bash
#
# Runs a real OpenSSH server for scripts/probes/check-sftp-contract.sh.
#
# The SFTP transport's two most dangerous behaviours cannot be observed against a fake:
# libssh2_sftp_write returns short constantly and silently truncates a file if the caller advances
# by the requested length rather than the returned one, and libssh2_sftp_rename_ex fails onto an
# existing file because its OVERWRITE flag is SFTP v5 and OpenSSH speaks v3. Both were measured
# against this container, and the probe keeps them measured.
#
# Usage:
#   sftp-test-server.sh up       # start it, wait until sshd sends its banner
#   sftp-test-server.sh down     # remove it
#   sftp-test-server.sh status   # report whether sshd answers
#
# The probe connects to 127.0.0.1:22022 and reads no environment variable, so it needs the
# default TABLEPRO_SFTP_TEST_PORT.

set -euo pipefail

# shellcheck source=lib/openssh-fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/openssh-fixture.sh"

CONTAINER="${TABLEPRO_SFTP_TEST_CONTAINER:-tp-sftp-it}"
PORT="${TABLEPRO_SFTP_TEST_PORT:-22022}"
USERNAME="tp"
PASSWORD="tppass"
IMAGE="$OPENSSH_FIXTURE_IMAGE_10"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 3
}

listening() {
    openssh_banner 127.0.0.1 "$PORT" > /dev/null
}

case "${1:-}" in
    up)
        if listening; then
            echo "sftp test server already listening on 127.0.0.1:$PORT"
            exit 0
        fi
        docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true
        docker run -d --name "$CONTAINER" \
            -p "127.0.0.1:$PORT:2222" \
            -e USER_NAME="$USERNAME" \
            -e USER_PASSWORD="$PASSWORD" \
            -e PASSWORD_ACCESS=true \
            -e SUDO_ACCESS=false \
            "$IMAGE" > /dev/null

        if openssh_wait_for_banner 127.0.0.1 "$PORT" 60; then
            echo "sftp test server listening on 127.0.0.1:$PORT as $USERNAME"
            exit 0
        fi
        echo "sftp test server sent no SSH banner within 60s" >&2
        docker logs "$CONTAINER" 2>&1 | tail -20 >&2
        exit 1
        ;;
    down)
        docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true
        echo "removed $CONTAINER"
        ;;
    status)
        if listening; then
            echo "listening on 127.0.0.1:$PORT"
        else
            echo "not listening on 127.0.0.1:$PORT"
            exit 1
        fi
        ;;
    *)
        usage
        ;;
esac
