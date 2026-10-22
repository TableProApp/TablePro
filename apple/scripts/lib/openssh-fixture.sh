# The pinned OpenSSH server images the SSH probes run against, and the readiness check they share.
#
# Sourced, never executed. A script in apple/scripts picks this up with:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/openssh-fixture.sh"
#
# Every function here starts with openssh_, because scripts/ci/check-lib-sourcing.py claims a
# library's function names for every script under apple/scripts.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # the image names are read by the scripts that source this

[ -n "${TABLEPRO_LIB_OPENSSH_FIXTURE_SOURCED:-}" ] && return 0
TABLEPRO_LIB_OPENSSH_FIXTURE_SOURCED=1

# Tag and digest, so a re-pushed tag cannot change the server under a probe. Both tags are the
# ones linux/crates/test-fixtures/src/fixture_image.rs runs. Both images run sshd as the login user
# and only that user can sign in.
OPENSSH_FIXTURE_IMAGE_10="linuxserver/openssh-server:version-10.3_p1-r1@sha256:0f535b0faa7448511b23528165e9fbd4f1fe563b861b3dcaa5ddb0ddbfe2254c"
OPENSSH_FIXTURE_IMAGE_9="linuxserver/openssh-server:version-9.9_p2-r0@sha256:edbbd662675be4f6a06c76c24f785adf68d7c69156152280842788e85d152a44"
OPENSSH_FIXTURE_REDIS_IMAGE="redis:8.8.3-alpine@sha256:0b2b77d3ea5078274795e3177cdbdada8b96316684a38911d528534ed679b5ec"

# Prints the server's identification line. An open port proves nothing: Docker's port proxy
# accepts a connection before sshd listens and then closes it, and libssh2 fails that connection
# with -13, "Failed getting banner".
openssh_banner() {
    local host="$1" port="$2" line
    line="$( (exec 3<> "/dev/tcp/$host/$port" && IFS= read -r -t 3 reply <&3 && printf '%s' "$reply") 2> /dev/null)" || return 1
    line="${line%$'\r'}"
    [[ "$line" == SSH-2.0-* ]] || return 1
    printf '%s\n' "$line"
}

openssh_wait_for_banner() {
    local host="$1" port="$2" seconds="${3:-60}" deadline
    deadline=$((SECONDS + seconds))
    while ((SECONDS < deadline)); do
        openssh_banner "$host" "$port" > /dev/null && return 0
        sleep 0.25
    done
    return 1
}
