#!/usr/bin/env bash
#
# Runs the OpenSSH servers scripts/probes/check-ssh-tunnel-matrix.sh opens tunnels through, each
# published on 127.0.0.1 only.
#
# One server per sshd configuration a cell needs, from the pinned images in
# scripts/lib/openssh-fixture.sh. Before a server's first start its /config gets a drop-in, the
# authorized keys and, on the TOTP servers, the code secret: the image writes its own sshd_config
# at init and includes the drop-in near the top, and sshd keeps the first value it reads. A drop-in
# is each ssh-test-servers/<variant>.conf a server names, then common.conf. The TOTP servers run an
# image built from ssh-test-servers/totp.Dockerfile. Every server shares one Docker network with
# redis, the query target behind each tunnel, and with hop2, which only the other servers reach.
# Neither is published.
#
# Usage:
#   ssh-test-servers.sh up [server...]   # start the servers, every one by default, and wait for each
#   ssh-test-servers.sh down             # remove the servers, their network and their keys
#   ssh-test-servers.sh status           # each server's banner, or why it has none
#   ssh-test-servers.sh kill <server>    # docker kill, which is how the connection-loss cell drops one
#   ssh-test-servers.sh start <server>   # start a killed server again and wait for its banner
#   ssh-test-servers.sh env              # NAME=value lines for a runner to eval
#
# Servers: v10 v9 pq10 pq9 kex10 cipher10 mac10 sha1kex rsahost sha1mac rsasig rsa256 rsa512 kbdpass passtotp
# passtotp1 keytotp totp maxauth hop1 hop2 loss.
# A bare up removes what an earlier up left and makes new keys; up with names restarts only those.
# Ports run from TABLEPRO_SSH_TEST_PORT_BASE + 1 (default 22601). Keys live in TABLEPRO_SSH_TEST_DIR
# (default $TMPDIR/tablepro-ssh-test-servers). decoy-1 to decoy-4 are keys no server accepts, for an
# agent that offers more keys than maxauth allows tries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/openssh-fixture.sh
source "$SCRIPT_DIR/lib/openssh-fixture.sh"

FIXTURE_DIR="$SCRIPT_DIR/ssh-test-servers"
STATE_DIR="${TABLEPRO_SSH_TEST_DIR:-${TMPDIR:-/tmp}/tablepro-ssh-test-servers}"
STATE_DIR="${STATE_DIR%/}"
STATE_MARKER="$STATE_DIR/.tablepro-ssh-test-servers"
PORT_BASE="${TABLEPRO_SSH_TEST_PORT_BASE:-22600}"
NETWORK="tp-ssh-matrix"
PREFIX="tp-ssh-"
LOGIN="tablepro"
PASSWORD="tppass"
KEY_PASSPHRASE="tp-key-pass"
# The usual documentation example: it signs in to these throwaway servers and nowhere else.
TOTP_SECRET="JBSWY3DPEHPK3PXP"
SERVERS="v10 v9 pq10 pq9 kex10 cipher10 mac10 sha1kex rsahost sha1mac rsasig rsa256 rsa512 kbdpass passtotp passtotp1 keytotp totp maxauth hop1 hop2 loss"
AUTHORIZED_KEYS="ed25519 ed25519-pass rsa rsa-pass ecdsa ecdsa-pass rsa-pem rsa-pem-pass ecdsa-pem ecdsa-pem-pass sk-ed25519"
DECOY_KEYS="decoy-1 decoy-2 decoy-3 decoy-4"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 3
}

die() {
    echo "$*" >&2
    exit 1
}

# image, port offset (- for unpublished), drop-in variants joined by + (- for none), PASSWORD_ACCESS.
# PASSWORD_ACCESS=false keeps /etc/shadow from sshd, so on totp and keytotp only the code signs in.
server_spec() {
    case "$1" in
        v10) echo "10 1 - true" ;;
        v9) echo "9 2 - true" ;;
        pq10) echo "10 3 pq-only true" ;;
        pq9) echo "9 4 pq-only true" ;;
        mac10) echo "10 5 mac-only true" ;;
        kex10) echo "10 16 kex-only true" ;;
        cipher10) echo "10 17 cipher-only true" ;;
        sha1kex) echo "10 18 sha1-kex true" ;;
        rsahost) echo "10 19 rsa-host-key true" ;;
        sha1mac) echo "10 20 sha1-mac true" ;;
        rsasig) echo "10 21 rsa-sha1-signature true" ;;
        rsa256) echo "10 6 rsa-sha2-256 true" ;;
        rsa512) echo "10 7 rsa-sha2-512 true" ;;
        kbdpass) echo "10 8 kbdint-password true" ;;
        passtotp) echo "totp 9 password-totp true" ;;
        passtotp1) echo "totp 15 password-totp+one-try true" ;;
        keytotp) echo "totp 10 publickey-totp false" ;;
        totp) echo "totp 11 totp false" ;;
        maxauth) echo "10 12 max-auth-tries true" ;;
        hop1) echo "10 13 - true" ;;
        hop2) echo "10 - - true" ;;
        loss) echo "10 14 - true" ;;
        *) return 1 ;;
    esac
}

server_port() {
    local image offset conf access
    read -r image offset conf access <<< "$(server_spec "$1")"
    [ "$offset" = "-" ] && return 1
    echo $((PORT_BASE + offset))
}

require_docker() {
    command -v docker > /dev/null 2>&1 || die "docker not found"
    docker info > /dev/null 2>&1 || die "Docker is not running"
}

require_server() {
    [ -n "${1:-}" ] || usage
    server_spec "$1" > /dev/null || die "unknown server: $1 (servers: $SERVERS)"
}

ensure_image() {
    docker image inspect "$1" > /dev/null 2>&1 || docker pull --quiet "$1" > /dev/null || die "could not pull $1"
}

# Tagged by what goes into it, so an edit to the Dockerfile or the PAM stack builds a new image.
totp_image() {
    local tag
    tag="tablepro-ssh-totp:$(
        {
            cat "$FIXTURE_DIR/totp.Dockerfile" "$FIXTURE_DIR/pam-sshd-totp"
            printf '%s' "$OPENSSH_FIXTURE_IMAGE_10"
        } | shasum -a 256 | cut -c1-12
    )"
    if ! docker image inspect "$tag" > /dev/null 2>&1; then
        echo "building $tag" >&2
        docker build --quiet --build-arg "OPENSSH_IMAGE=$OPENSSH_FIXTURE_IMAGE_10" \
            -t "$tag" -f "$FIXTURE_DIR/totp.Dockerfile" "$FIXTURE_DIR" > /dev/null || die "could not build $tag"
    fi
    echo "$tag"
}

keygen() {
    local name="$1" type="$2" passphrase="$3"
    shift 3
    ssh-keygen -q -t "$type" -N "$passphrase" -C "tablepro-$name" -f "$STATE_DIR/keys/$name" "$@" < /dev/null
}

# keys-nopub/ holds the same private keys without their .pub: the app reads a .pub next to a key
# file when there is one and derives the public key otherwise, and the two paths fail differently.
make_keys() {
    local name
    rm -rf "$STATE_DIR/keys" "$STATE_DIR/keys-nopub"
    mkdir -p "$STATE_DIR/keys" "$STATE_DIR/keys-nopub"
    keygen ed25519 ed25519 ""
    keygen ed25519-pass ed25519 "$KEY_PASSPHRASE"
    keygen rsa rsa "" -b 3072
    keygen rsa-pass rsa "$KEY_PASSPHRASE" -b 3072
    keygen ecdsa ecdsa "" -b 256
    keygen ecdsa-pass ecdsa "$KEY_PASSPHRASE" -b 256
    keygen rsa-pem rsa "" -b 3072 -m PEM
    keygen rsa-pem-pass rsa "$KEY_PASSPHRASE" -b 3072 -m PEM
    keygen ecdsa-pem ecdsa "" -b 256 -m PEM
    keygen ecdsa-pem-pass ecdsa "$KEY_PASSPHRASE" -b 256 -m PEM
    keygen stray-pass ed25519 "$KEY_PASSPHRASE"
    for name in $DECOY_KEYS; do
        keygen "$name" ed25519 ""
    done
    python3 -I "$FIXTURE_DIR/make-sk-key.py" "$STATE_DIR/keys/sk-ed25519"
    for name in $AUTHORIZED_KEYS stray-pass $DECOY_KEYS; do
        cp -p "$STATE_DIR/keys/$name" "$STATE_DIR/keys-nopub/$name"
    done
}

stage_server() {
    local name="$1" image="$2" conf="$3" stage="$STATE_DIR/stage/$1" key variant
    rm -rf "$stage"
    mkdir -p "$stage/sshd/sshd_config.d" "$stage/.ssh"
    {
        if [ "$conf" != "-" ]; then
            for variant in ${conf//+/ }; do
                cat "$FIXTURE_DIR/$variant.conf"
            done
        fi
        cat "$FIXTURE_DIR/common.conf"
    } > "$stage/sshd/sshd_config.d/tablepro.conf"
    for key in $AUTHORIZED_KEYS; do
        cat "$STATE_DIR/keys/$key.pub"
    done > "$stage/.ssh/authorized_keys"
    if [ "$image" = "totp" ]; then
        printf '%s\n" TOTP_AUTH\n' "$TOTP_SECRET" > "$stage/.google_authenticator"
        chmod 600 "$stage/.google_authenticator"
    fi
}

image_ref() {
    case "$1" in
        10) echo "$OPENSSH_FIXTURE_IMAGE_10" ;;
        9) echo "$OPENSSH_FIXTURE_IMAGE_9" ;;
        totp) echo "$TOTP_IMAGE" ;;
    esac
}

# docker cp into a created container lands before init runs. /config/sshd does not exist yet, so
# the drop-in has to arrive inside its directory, not as a single file.
create_server() {
    local name="$1" image offset conf access container="$PREFIX$1"
    read -r image offset conf access <<< "$(server_spec "$name")"
    stage_server "$name" "$image" "$conf"
    local args=(
        --name "$container" --network "$NETWORK" --network-alias "$name"
        -e "USER_NAME=$LOGIN" -e "USER_PASSWORD=$PASSWORD" -e "PASSWORD_ACCESS=$access"
        -e SUDO_ACCESS=false -e LOG_STDOUT=true
    )
    if [ "$offset" != "-" ]; then
        args+=(-p "127.0.0.1:$((PORT_BASE + offset)):2222")
    fi
    docker rm -f -v "$container" > /dev/null 2>&1 || true
    docker create "${args[@]}" "$(image_ref "$image")" > /dev/null
    docker cp "$STATE_DIR/stage/$name/." "$container:/config/"
    docker start "$container" > /dev/null
}

# hop2 is not published, so its banner is read from inside its own container.
wait_ready() {
    local name="$1" port
    if port="$(server_port "$name")"; then
        openssh_wait_for_banner 127.0.0.1 "$port" 90 && return 0
    else
        local deadline=$((SECONDS + 90))
        while ((SECONDS < deadline)); do
            docker exec "$PREFIX$name" bash -c \
                'exec 3<> /dev/tcp/127.0.0.1/2222 && IFS= read -r -t 3 line <&3 && [[ $line == SSH-2.0-* ]]' \
                > /dev/null 2>&1 && return 0
            sleep 0.25
        done
    fi
    echo "$name sent no SSH banner within 90s; its log:" >&2
    docker logs "$PREFIX$name" 2>&1 | tail -20 >&2
    return 1
}

start_redis() {
    local container="${PREFIX}redis" _
    docker rm -f -v "$container" > /dev/null 2>&1 || true
    docker run -d --name "$container" --network "$NETWORK" --network-alias redis \
        "$OPENSSH_FIXTURE_REDIS_IMAGE" redis-server --save "" --appendonly no --protected-mode no > /dev/null
    for _ in $(seq 1 120); do
        [ "$(docker exec "$container" redis-cli ping 2> /dev/null)" = "PONG" ] && return 0
        sleep 0.25
    done
    die "redis did not answer PING within 30s"
}

remove_all() {
    local name
    for name in $SERVERS redis; do
        docker rm -f -v "$PREFIX$name" > /dev/null 2>&1 || true
    done
    docker network rm "$NETWORK" > /dev/null 2>&1 || true
}

cmd_up() {
    local names="$*" name image offset conf access needs_totp=0
    require_docker
    for name in $names; do
        require_server "$name"
    done
    if [ -z "$names" ]; then
        names="$SERVERS"
        remove_all
        mkdir -p "$STATE_DIR"
        touch "$STATE_MARKER"
        make_keys
    elif [ ! -f "$STATE_DIR/keys/ed25519" ]; then
        die "no keys in $STATE_DIR; run a bare up first"
    fi

    for name in $names; do
        read -r image offset conf access <<< "$(server_spec "$name")"
        [ "$image" = "totp" ] && needs_totp=1
    done
    ensure_image "$OPENSSH_FIXTURE_IMAGE_10"
    ensure_image "$OPENSSH_FIXTURE_IMAGE_9"
    ensure_image "$OPENSSH_FIXTURE_REDIS_IMAGE"
    TOTP_IMAGE=""
    if [ "$needs_totp" = 1 ]; then
        TOTP_IMAGE="$(totp_image)"
    fi

    docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create "$NETWORK" > /dev/null
    if [ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}redis" 2> /dev/null)" != "true" ]; then
        start_redis
    fi
    for name in $names; do
        create_server "$name"
    done
    for name in $names; do
        wait_ready "$name" || exit 1
    done
    echo "SSH test servers ready: $names"
}

cmd_down() {
    remove_all
    if [ -f "$STATE_MARKER" ]; then
        rm -rf "$STATE_DIR/keys" "$STATE_DIR/keys-nopub" "$STATE_DIR/stage"
        rm -f "$STATE_MARKER"
        rmdir "$STATE_DIR" 2> /dev/null || true
    fi
    echo "removed the SSH test servers"
}

cmd_status() {
    local name state port banner failed=0
    for name in $SERVERS redis; do
        state="$(docker inspect -f '{{.State.Status}}' "$PREFIX$name" 2> /dev/null || echo "missing")"
        if [ "$state" != "running" ]; then
            printf '%-9s %s\n' "$name" "$state"
            failed=1
        elif [ "$name" = "redis" ] || ! port="$(server_port "$name")"; then
            printf '%-9s running, not published\n' "$name"
        elif banner="$(openssh_banner 127.0.0.1 "$port")"; then
            printf '%-9s 127.0.0.1:%s %s\n' "$name" "$port" "$banner"
        else
            printf '%-9s 127.0.0.1:%s no banner\n' "$name" "$port"
            failed=1
        fi
    done
    return "$failed"
}

cmd_env() {
    local name port
    printf 'SSH_TEST_HOST=127.0.0.1\n'
    printf 'SSH_TEST_USER=%q\n' "$LOGIN"
    printf 'SSH_TEST_PASSWORD=%q\n' "$PASSWORD"
    printf 'SSH_TEST_KEY_PASSPHRASE=%q\n' "$KEY_PASSPHRASE"
    printf 'SSH_TEST_TOTP_SECRET=%q\n' "$TOTP_SECRET"
    printf 'SSH_TEST_KEYS=%q\n' "$STATE_DIR/keys"
    printf 'SSH_TEST_KEYS_NOPUB=%q\n' "$STATE_DIR/keys-nopub"
    printf 'SSH_TEST_DECOY_KEYS=%q\n' "$DECOY_KEYS"
    printf 'SSH_TEST_TARGET=redis:6379\n'
    printf 'SSH_TEST_HOP2=hop2:2222\n'
    for name in $SERVERS; do
        port="$(server_port "$name")" || continue
        printf 'SSH_TEST_PORT_%s=%s\n' "$(echo "$name" | tr '[:lower:]' '[:upper:]')" "$port"
    done
}

case "${1:-}" in
    up)
        shift
        cmd_up "$@"
        ;;
    down)
        cmd_down
        ;;
    status)
        cmd_status
        ;;
    kill)
        require_server "${2:-}"
        docker kill "$PREFIX$2" > /dev/null
        echo "killed $2"
        ;;
    start)
        require_server "${2:-}"
        docker start "$PREFIX$2" > /dev/null
        wait_ready "$2"
        echo "$2 ready"
        ;;
    env)
        cmd_env
        ;;
    *)
        usage
        ;;
esac
