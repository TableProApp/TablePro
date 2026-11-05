#!/bin/sh
# Keeps a TablePro Flatpak repository as flatpak.tablepro.app serves it:
# repo/ holds releases on the branch stable and beta-repo/ betas on the
# branch beta, as Flathub keeps flathub and flathub-beta. Every commit and
# the summary are signed with one GPG key from GNUPGHOME, the summary carries
# static deltas, each ref keeps its last 3 commits, and the repository holds
# a .flatpakrepo that adds it as a remote and a .flatpakref that installs the
# app, with Flathub named for the runtime. release-linux.yml runs this with
# the release key; CI's install test with a throwaway one.
#
# Usage:
#   flatpak-repo.sh import <build repo> <repo> <key> [<branch>]
#       Commits the app and its .Debug extension of each architecture in the
#       build repo to <repo>, signed, on <branch> when given.
#   flatpak-repo.sh update <repo> <branch> <key> <url>
#       Writes the signed summary and the deltas, prunes, and writes the
#       .flatpakrepo and .flatpakref that name <url>, where <repo> is served.
#   flatpak-repo.sh bundle <repo> <branch> <key> <url> <output dir>
#       Writes tablepro-<arch>.flatpak for each architecture; an installed
#       bundle updates from <url>.
set -eu

app=app.tablepro.TablePro
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo

usage() {
    sed -n 's/^#   //p' "$0" >&2
    exit 2
}

check_branch() {
    case "$1" in
    stable | beta) ;;
    *)
        echo "flatpak-repo.sh: the branch is stable or beta, not $1" >&2
        exit 2
        ;;
    esac
}

app_refs() {
    ostree refs --repo="$1" | grep "^app/$app/[^/]*/$2\$" || true
}

import() {
    src="$1"
    repo="$2"
    if [ -n "${4:-}" ]; then
        check_branch "$4"
    fi
    if [ ! -d "$repo/objects" ]; then
        mkdir -p "$repo"
        ostree init --mode=archive-z2 --repo="$repo"
    fi
    if [ -z "$(ostree refs --repo="$src" | grep "^app/$app/" || true)" ]; then
        echo "flatpak-repo.sh: $src holds no $app" >&2
        exit 1
    fi
    for ref in $(ostree refs --repo="$src" | grep -E "^(app/$app|runtime/$app\.Debug)/" || true); do
        target="$ref"
        if [ -n "${4:-}" ]; then
            target="${ref%/*}/$4"
        fi
        flatpak build-commit-from --gpg-sign="$3" --src-repo="$src" --src-ref="$ref" \
            --no-update-summary --force "$repo" "$target"
    done
}

update() {
    repo="$1"
    branch="$2"
    url="$4"
    check_branch "$branch"
    if [ "$branch" = beta ]; then
        title="TablePro beta"
        remote=tablepro-beta
    else
        title=TablePro
        remote=tablepro
    fi
    if [ -z "$(app_refs "$repo" "$branch")" ]; then
        echo "flatpak-repo.sh: $repo holds no $app on $branch" >&2
        exit 1
    fi
    flatpak build-update-repo --gpg-sign="$3" --generate-static-deltas --prune --prune-depth=3 \
        --title="$title" --homepage=https://tablepro.app --default-branch="$branch" "$repo"
    key="$(gpg --batch --export "$3" | base64 --wrap=0)"
    cat > "$repo/$remote.flatpakrepo" <<EOF
[Flatpak Repo]
Title=$title
Url=$url
Homepage=https://tablepro.app
Comment=TablePro for Linux, the database client
DefaultBranch=$branch
GPGKey=$key
EOF
    cat > "$repo/$app.flatpakref" <<EOF
[Flatpak Ref]
Title=$title
Name=$app
Branch=$branch
Url=$url
SuggestRemoteName=$remote
Homepage=https://tablepro.app
IsRuntime=false
RuntimeRepo=$flathub
GPGKey=$key
EOF
}

bundle() {
    repo="$1"
    branch="$2"
    url="$4"
    check_branch "$branch"
    mkdir -p "$5"
    keys="$(mktemp)"
    gpg --batch --export "$3" > "$keys"
    refs="$(app_refs "$repo" "$branch")"
    if [ -z "$refs" ]; then
        echo "flatpak-repo.sh: $repo holds no $app on $branch" >&2
        exit 1
    fi
    for ref in $refs; do
        arch="$(echo "$ref" | cut -d/ -f3)"
        flatpak build-bundle --arch="$arch" --repo-url="$url" --runtime-repo="$flathub" \
            --gpg-keys="$keys" "$repo" "$5/tablepro-$arch.flatpak" "$app" "$branch"
    done
    rm -f "$keys"
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
import)
    [ $# -eq 3 ] || [ $# -eq 4 ] || usage
    import "$@"
    ;;
update)
    [ $# -eq 4 ] || usage
    update "$@"
    ;;
bundle)
    [ $# -eq 5 ] || usage
    bundle "$@"
    ;;
*) usage ;;
esac
