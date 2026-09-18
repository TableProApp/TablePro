#!/usr/bin/env bash
#
# Runs a real OpenSSH server for the SFTP integration tests.
#
# The SFTP transport's two most dangerous behaviours cannot be observed against a fake:
# libssh2_sftp_write returns short constantly and silently truncates a file if the caller advances
# by the requested length rather than the returned one, and libssh2_sftp_rename_ex fails onto an
# existing file because its OVERWRITE flag is SFTP v5 and OpenSSH speaks v3. Both were measured
# against this container, and LibSSH2SFTPSessionIntegrationTests keeps them measured.
#
# Usage:
#   sftp-test-server.sh up       # start it, wait until it answers
#   sftp-test-server.sh down     # remove it
#   sftp-test-server.sh status   # report whether it is listening
#
# The tests find it by connecting, not by reading an environment variable: xcodebuild does not
# pass the invoking shell's environment to the test host, so an exported variable arrives as
# nothing and the suite silently reports zero cases.

set -euo pipefail

CONTAINER="${TABLEPRO_SFTP_TEST_CONTAINER:-tp-sftp-it}"
PORT="${TABLEPRO_SFTP_TEST_PORT:-22022}"
USERNAME="tp"
PASSWORD="tppass"
IMAGE="lscr.io/linuxserver/openssh-server:latest"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 3
}

listening() {
    nc -z -w 2 127.0.0.1 "$PORT" > /dev/null 2>&1
}

case "${1:-}" in
    up)
        if listening; then
            echo "sftp test server already listening on 127.0.0.1:$PORT"
            exit 0
        fi
        docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
        docker run -d --name "$CONTAINER" \
            -p "$PORT:2222" \
            -e USER_NAME="$USERNAME" \
            -e USER_PASSWORD="$PASSWORD" \
            -e PASSWORD_ACCESS=true \
            -e SUDO_ACCESS=false \
            "$IMAGE" > /dev/null

        for _ in $(seq 1 60); do
            if listening; then
                echo "sftp test server listening on 127.0.0.1:$PORT as $USERNAME"
                exit 0
            fi
            sleep 1
        done
        echo "sftp test server did not start within 60s" >&2
        docker logs "$CONTAINER" 2>&1 | tail -20 >&2
        exit 1
        ;;
    down)
        docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
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
