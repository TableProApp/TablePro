#!/usr/bin/env bash
# Submit an artifact to Apple's notary service, staple the ticket, and prove it will open.
# Source this; it defines notarize_and_staple and sets nothing else.
#
# This existed three times at three rigor levels. build-plugin.sh stapled, validated and asked
# Gatekeeper; create-dmg.sh stapled and validated; build-release.sh only stapled, and it was the
# only one that fetched the notary log when a submission failed. So the app, the artifact users
# actually download, got the weakest checks and the DMG and plugins got the best diagnostics
# withheld. One implementation, at the strictest level all three reached between them.
#
# The two post-staple checks are not redundant. spctl asks Gatekeeper, which will fetch the
# ticket from Apple over the network, so an artifact that was notarized but never successfully
# stapled still passes: /Applications/Ghostty.app has no ticket and spctl accepts it. Only
# `stapler validate` proves the ticket is in the artifact, which is what an offline Mac needs.

# The apple-signing action's "Configure notarization" step stores the Apple ID, team and
# app-specific password under this profile name, so --keychain-profile is the whole credential
# and passing --apple-id or --team-id alongside it is redundant. A local build with its own
# stored profile can override the name.
NOTARY_PROFILE="${NOTARY_PROFILE:-TablePro}"

# Usage: notarize_and_staple <path> [exec|open]
#
# The second argument is the Gatekeeper assessment type: "exec" for an application, "open" for a
# disk image or a plugin bundle, which a user opens rather than launches.
notarize_and_staple() {
    local path="${1:?notarize_and_staple needs a path}"
    local assessment="${2:-exec}"
    local name
    name="$(basename "$path")"

    [ -e "$path" ] || { echo "FATAL: nothing to notarize at $path" >&2; return 1; }

    # notarytool only accepts an archive, so a bundle is zipped to a throwaway path. The ticket
    # is then stapled into the bundle itself, not the zip: without that every user needs a live
    # round trip to Apple on first load and an offline Mac never gets one. Stapling rewrites the
    # artifact, so any distribution zip and its checksum must be produced after this returns.
    local submission="$path" scratch=""
    if [ -d "$path" ]; then
        scratch="$(mktemp -d)"
        submission="$scratch/${name}.zip"
        ditto -c -k --keepParent "$path" "$submission"
    fi

    echo "Submitting $name for notarization..."
    # Assigned before the substitution, then overwritten on failure. Written the other way round,
    # `status=$?` reads the exit status of the assignment, which is always 0, so every failure
    # took the success branch and the log fetch below was unreachable.
    local submit_status=0 output=""
    output="$(xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || submit_status=$?
    echo "$output"
    [ -z "$scratch" ] || rm -rf "$scratch"

    # Both checks, because notarytool has shipped versions that exit 0 on a rejected submission.
    if [ "$submit_status" -ne 0 ] || ! echo "$output" | grep -q "status: Accepted"; then
        echo "FATAL: notarization failed for $name" >&2
        local submission_id
        submission_id="$(echo "$output" | grep "id:" | head -1 | awk '{print $2}')"
        if [ -n "$submission_id" ]; then
            echo "Notary log for $submission_id:" >&2
            xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 2>&1 || true
        fi
        return 1
    fi

    echo "Stapling the ticket into $name..."
    xcrun stapler staple "$path" || { echo "FATAL: stapling failed for $name" >&2; return 1; }

    # Stapling can report success and still leave no usable ticket.
    xcrun stapler validate "$path" || { echo "FATAL: the stapled ticket did not validate for $name" >&2; return 1; }

    # spctl is what a user's Mac runs. A pass here is the only proof the artifact will open.
    local assessment_output
    if ! assessment_output="$(spctl -a -vvv -t "$assessment" --context context:primary-signature "$path" 2>&1)" \
        || ! echo "$assessment_output" | grep -q "accepted"; then
        echo "FATAL: Gatekeeper still rejects $name after notarization" >&2
        echo "$assessment_output" >&2
        return 1
    fi

    echo "$name notarized, stapled and accepted by Gatekeeper"
}
