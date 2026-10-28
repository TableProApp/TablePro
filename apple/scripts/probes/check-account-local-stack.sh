#!/usr/bin/env bash
#
# Run the account services against a local tablepro-cloud stack (web/e2e's global setup, with its fake Resend and
# fake Polar), end to end: an interactive sign-in through the account pages in headless Chrome, device
# registration, the token refresh that names the device, the entitlement checked with the stack's key, refresh
# token rotation, sign-out revoking the refresh token, a seeded legacy key migrating with no refresh, an unknown
# key refused, and a fourth device answered with device_limit_reached and its 3 holders.
#
# account-local-stack/main.swift drives the app's own Core/Services/Account sources, built into a SwiftPM
# executable beside AppStubs.swift. seed.cjs inserts the accounts it needs; nothing is deleted.
#
# Usage:
#   scripts/probes/check-account-local-stack.sh
#
# TABLEPRO_CLOUD    the tablepro-cloud checkout (default: beside this repository); its web/e2e/node_modules
#                   gives pg, and web/e2e/.stack/keys/entitlement the stack's entitlement key
# TABLEPRO_ACCOUNT_URL, TABLEPRO_API_URL   default http://account.localhost:5284, http://api.localhost:5284
# DATABASE_URL      default the e2e stack's database on 127.0.0.1:55436
# MAIL_URL          the fake Resend, default http://127.0.0.1:5285
# PROBE_EMAIL_DOMAIN  the seeded addresses' domain, default account-probe.example
# PROBE_CHROME      a Chrome or chrome-headless-shell for Puppeteer, else Puppeteer's own
#
# Needs node with puppeteer installed globally, and xcrun swift. Exits 0 when every check passes, 1 when one
# fails, 3 when it cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/probes/account-local-stack"
CLOUD="${TABLEPRO_CLOUD:-$ROOT/../../tablepro-cloud}"
export TABLEPRO_ACCOUNT_URL="${TABLEPRO_ACCOUNT_URL:-http://account.localhost:5284}"
export TABLEPRO_API_URL="${TABLEPRO_API_URL:-http://api.localhost:5284}"
export DATABASE_URL="${DATABASE_URL:-postgres://postgres:test@127.0.0.1:55436/tablepro_cloud_e2e_5284?sslmode=disable}"
export MAIL_URL="${MAIL_URL:-http://127.0.0.1:5285}"
DOMAIN="${PROBE_EMAIL_DOMAIN:-account-probe.example}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cannot_run() {
    echo "$1" >&2
    exit 3
}

command -v node > /dev/null || cannot_run "node not found"
[ -d "$CLOUD/web/e2e/node_modules/pg" ] || cannot_run "no pg in $CLOUD/web/e2e/node_modules; set TABLEPRO_CLOUD"
NODE_PATH="$CLOUD/web/e2e/node_modules:$(npm root -g)"
export NODE_PATH
node -e 'require("puppeteer")' 2> /dev/null || cannot_run "puppeteer not found; npm install -g puppeteer"
curl -fsS -o /dev/null "$TABLEPRO_API_URL/readyz" || cannot_run "no tablepro-cloud answers at $TABLEPRO_API_URL/readyz"

KEY_FILE="$CLOUD/web/e2e/.stack/keys/entitlement"
[ -f "$KEY_FILE" ] || cannot_run "no entitlement key at $KEY_FILE; is the stack from web/e2e running?"
TABLEPRO_ENTITLEMENT_KEYS="$(node -e 'const c = require("node:crypto"); console.log(c.createPublicKey(require("node:fs").readFileSync(process.argv[1])).export({ format: "jwk" }).x)' "$KEY_FILE")" \
    || cannot_run "could not read the stack's entitlement public key"
export TABLEPRO_ENTITLEMENT_KEYS

node "$PROBE/seed.cjs" "$WORK/config.json" "$DOMAIN" || cannot_run "seeding the local stack failed"

mkdir -p "$WORK/Sources/Probe"
SOURCES="$WORK/Sources/Probe"
for source in "$ROOT"/TablePro/Core/Services/Account/*.swift; do
    case "$(basename "$source")" in
        AccountServices+Live.swift | LicenseSignatureVerifier.swift) continue ;;
    esac
    ln -s "$source" "$SOURCES/$(basename "$source")"
done
for source in Models/Settings/ProFeature.swift Core/Diagnostics/LogRedaction.swift Extensions/Bundle+AppInfo.swift; do
    ln -s "$ROOT/TablePro/$source" "$SOURCES/$(basename "$source")"
done
ln -s "$PROBE/AppStubs.swift" "$SOURCES/AppStubs.swift"
ln -s "$PROBE/main.swift" "$SOURCES/Probe.swift"
cp "$ROOT/TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$WORK/Package.resolved" 2> /dev/null
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AccountLocalStackProbe", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProCore"),
        .package(path: "$ROOT/Packages/TableProMacCore")
    ],
    targets: [
        .executableTarget(name: "Probe", dependencies: [
            .product(name: "TableProCloudAPI", package: "TableProMacCore"),
            .product(name: "TableProLogRedaction", package: "TableProCore")
        ], swiftSettings: [
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("MemberImportVisibility")
        ])
    ])
MANIFEST
echo "building the probe"
if ! (cd "$WORK" && xcrun swift build --jobs 4 > "$WORK/build.log" 2>&1); then
    tail -60 "$WORK/build.log" >&2
    cannot_run "the probe did not build"
fi

PROBE_SIGN_IN_SCRIPT="$PROBE/sign-in.cjs" "$WORK/.build/debug/Probe" "$WORK/config.json"
