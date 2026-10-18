#!/bin/sh
# The COPR package's custom source method: COPR runs this in a Fedora
# chroot, unprivileged and with network, and builds the source RPM from
# the spec and sources it leaves in the working directory.
# release-linux.yml posts the release tag to the project's custom webhook,
# and COPR hands the body over as ./hook_payload.
#
# COPR runs its own copy of this file. After a change, a maintainer runs:
#   copr-cli edit-package-custom <owner>/tablepro --name tablepro \
#       --script linux/build-aux/rpm/copr-sources.sh \
#       --script-builddeps 'curl rpmdevtools'
set -eu

tag="$(cat hook_payload)"
case "$tag" in
    *[!0-9A-Za-z.-]*)
        echo "copr-sources.sh: not a release tag: $tag" >&2
        exit 1
        ;;
    linux-v[0-9]*) ;;
    *)
        echo "copr-sources.sh: not a Linux release tag: $tag" >&2
        exit 1
        ;;
esac

curl --fail --silent --show-error --location --proto '=https' \
    --output tablepro.spec \
    "https://raw.githubusercontent.com/TableProApp/TablePro/$tag/linux/build-aux/rpm/tablepro.spec"
spectool --get-files --sources tablepro.spec
