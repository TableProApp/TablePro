#!/bin/sh
# Copies a TablePro Flatpak repository between this machine and the
# tablepro-flatpak R2 bucket that https://flatpak.tablepro.app serves, with
# rclone and the r2 remote that the RCLONE_CONFIG_R2_* variables configure.
#
# push uploads the new objects and deltas first, then the refs, the
# .flatpakrepo, the .flatpakref and last the summaries, so a client never
# reads a summary that names an object not there yet. Only then does it
# delete what pruning removed, which no summary names any more.
#
# Usage:
#   flatpak-publish.sh install-rclone
#       Installs rclone 1.75.2, checked against its SHA-256, as root.
#   flatpak-publish.sh pull <repo|beta-repo> <local repo>
#   flatpak-publish.sh push <local repo> <repo|beta-repo>
# No globbing: the rclone filters are patterns.
set -euf

bucket=r2:tablepro-flatpak
rclone_version=1.75.2

usage() {
    sed -n 's/^#   //p' "$0" >&2
    exit 2
}

check_dir() {
    case "$1" in
    repo | beta-repo) ;;
    *)
        echo "flatpak-publish.sh: the repository is repo or beta-repo, not $1" >&2
        exit 2
        ;;
    esac
}

install_rclone() {
    case "$(uname -m)" in
    x86_64)
        platform=linux-amd64
        sum=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
        ;;
    aarch64)
        platform=linux-arm64
        sum=7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10
        ;;
    *)
        echo "flatpak-publish.sh: no rclone for $(uname -m)" >&2
        exit 1
        ;;
    esac
    work="$(mktemp -d)"
    name="rclone-v$rclone_version-$platform"
    curl --fail --silent --show-error --location --proto '=https' --output "$work/$name.zip" \
        "https://github.com/rclone/rclone/releases/download/v$rclone_version/$name.zip"
    echo "$sum  $work/$name.zip" | sha256sum --check --strict
    unzip -q "$work/$name.zip" -d "$work"
    install -m 0755 "$work/$name/rclone" /usr/local/bin/rclone
    rm -rf "$work"
    rclone version
}

# ostree's own working state never leaves the machine.
local_only() {
    set -- --exclude "/tmp/**" --exclude "/state/**" --exclude "/.lock"
    echo "$@"
}

pull() {
    check_dir "$1"
    mkdir -p "$2"
    # A repository not published yet has no objects to fetch.
    if rclone lsf --max-depth 1 "$bucket/$1" 2>/dev/null | grep -q .; then
        rclone copy --fast-list "$bucket/$1" "$2"
    fi
}

push() {
    check_dir "$2"
    from="$1"
    to="$bucket/$2"
    meta="Cache-Control: no-cache"
    # shellcheck disable=SC2046 # one word per option
    rclone copy --fast-list $(local_only) --exclude "/refs/**" --exclude "/summaries/**" \
        --exclude "/summary*" --exclude "/config" --exclude "/*.flatpakrepo" --exclude "/*.flatpakref" \
        "$from" "$to"
    # shellcheck disable=SC2046
    rclone copy --fast-list $(local_only) --header-upload "$meta" \
        --include "/refs/**" --include "/config" --include "/*.flatpakrepo" --include "/*.flatpakref" \
        "$from" "$to"
    # shellcheck disable=SC2046
    rclone copy --fast-list $(local_only) --header-upload "$meta" --include "/summaries/**" "$from" "$to"
    for file in summary.idx summary.idx.sig summary summary.sig; do
        if [ -f "$from/$file" ]; then
            rclone copyto --header-upload "$meta" "$from/$file" "$to/$file"
        fi
    done
    # shellcheck disable=SC2046
    rclone sync --fast-list $(local_only) "$from" "$to"
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
install-rclone)
    [ $# -eq 0 ] || usage
    install_rclone
    ;;
pull)
    [ $# -eq 2 ] || usage
    pull "$@"
    ;;
push)
    [ $# -eq 2 ] || usage
    push "$@"
    ;;
*) usage ;;
esac
