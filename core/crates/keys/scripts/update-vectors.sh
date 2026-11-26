#!/bin/sh
# Writes core/crates/keys/vectors (core ADR 0056, Vectors) and the word table.
#
#   update-vectors.sh              the crate's own vectors, from src/vectors with every random input
#                                  drawn from its case's name, so a run writes the same bytes; a
#                                  wrap keeps the committed enc and ct while they still open, since
#                                  HPKE draws its own ephemeral key
#   update-vectors.sh --standard   also downloads the standard vectors again: RFC 9180's at the
#                                  revision the ADR names and Wycheproof's at WYCHEPROOF below, each
#                                  checked against its SHA-256, then cut to what suite tp1 uses
#
# The word table src/words/eff_large.rs is written from src/words/eff_large_wordlist.txt, whose
# SHA-256 is pinned. The test the_vectors_are_what_the_generator_writes fails when a file is stale.
set -eu

crate="$(cd "$(dirname "$0")/.." && pwd)"
vectors="$crate/vectors"

HPKE_REVISION=5f503c564da00b0687b3de75f1dfbdfc4079ad31
HPKE_SHA256=61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6
WYCHEPROOF=65ca494727a52944c204441c860b039e6786b99b
EFF_SHA256=addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e

sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

fetch() {
    curl --fail --silent --show-error --location --output "$2" "$1"
    if [ "$(sha256 "$2")" != "$3" ]; then
        echo "update-vectors.sh: $1 does not have SHA-256 $3" >&2
        exit 1
    fi
}

if [ "${1:-}" = --standard ]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    fetch "https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hpke/$HPKE_REVISION/test-vectors.json" "$work/hpke.json" "$HPKE_SHA256"
    fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF/testvectors_v1/aes_gcm_test.json" "$work/aes_gcm.json" \
        985e5ecc172e181eaf49e89508b9470dcf478002eb7e8559c707eb42dc97dfe7
    fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF/testvectors_v1/x25519_test.json" "$work/x25519.json" \
        35c3f5231cf25cc640b524d403461deee9e49441d5d915a3a25b2c8ff5adbe7d
    fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF/testvectors_v1/ed25519_test.json" "$work/ed25519.json" \
        ea80ffebac085e21cb9d3e903e7fa2b448d96702da5b31f061d0b83b430b74b3
    fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF/testvectors_v1/hkdf_sha256_test.json" "$work/hkdf.json" \
        bb2b462a38b251cb52a2aede706d6d4b62b26864f4e80c95497507ddb07c5f1e
    mkdir -p "$vectors/standard"
    python3 -I - "$work" "$vectors/standard" "$HPKE_REVISION" "$WYCHEPROOF" <<'PY'
import hashlib, json, sys
work, out, hpke_revision, wycheproof = sys.argv[1:5]

def upstream(name):
    with open(f"{work}/{name}", "rb") as file:
        data = file.read()
    return json.loads(data), hashlib.sha256(data).hexdigest()

def write(name, source, digest, kept, vectors):
    with open(f"{out}/{name}", "w") as file:
        json.dump({"source": source, "upstream_sha256": digest, "kept": kept, "vectors": vectors}, file, indent=1)
        file.write("\n")

hpke, digest = upstream("hpke.json")
write("rfc9180.json", f"https://github.com/cfrg/draft-irtf-cfrg-hpke/blob/{hpke_revision}/test-vectors.json", digest,
      "the entries for KEM 0x0020, KDF 0x0001 and AEAD 0x0002, every mode",
      [entry for entry in hpke if (entry["kem_id"], entry["kdf_id"], entry["aead_id"]) == (32, 1, 2)])

base = f"https://github.com/C2SP/wycheproof/blob/{wycheproof}/testvectors_v1"
gcm, digest = upstream("aes_gcm.json")
gcm["testGroups"] = [group for group in gcm["testGroups"] if (group["keySize"], group["ivSize"], group["tagSize"]) == (256, 96, 128)]
write("wycheproof_aes_gcm.json", f"{base}/aes_gcm_test.json", digest, "the groups with a 256-bit key, a 96-bit nonce and a 128-bit tag", gcm)

x25519, digest = upstream("x25519.json")
write("wycheproof_x25519.json", f"{base}/x25519_test.json", digest, "all", x25519)

ed25519, digest = upstream("ed25519.json")
for group in ed25519["testGroups"]:
    for encoding in ("publicKeyDer", "publicKeyPem", "publicKeyJwk"):
        group.pop(encoding, None)
write("wycheproof_ed25519.json", f"{base}/ed25519_test.json", digest, "all tests; each group's raw public key only", ed25519)

hkdf, digest = upstream("hkdf.json")
write("wycheproof_hkdf_sha256.json", f"{base}/hkdf_sha256_test.json", digest, "all", hkdf)
PY
fi

list="$crate/src/words/eff_large_wordlist.txt"
if [ "$(sha256 "$list")" != "$EFF_SHA256" ]; then
    echo "update-vectors.sh: $list is not the pinned EFF large word list" >&2
    exit 1
fi
python3 -I - "$list" "$crate/src/words/eff_large.rs" <<'PY'
import itertools, sys
source, target = sys.argv[1:3]
lines = open(source, encoding="ascii").read().split("\n")
assert lines[-1] == "" and len(lines) == 7777
words = []
for line, dice in zip(lines[:-1], itertools.product("123456", repeat=5)):
    number, word = line.split("\t")
    assert number == "".join(dice), line
    words.append(word)
with open(target, "w") as file:
    file.write("// Generated from eff_large_wordlist.txt by core/crates/keys/scripts/update-vectors.sh. Do not edit.\n\n")
    file.write("pub(super) static EFF_LARGE: [&str; 7776] = [\n")
    for word in words:
        file.write(f'    "{word}",\n')
    file.write("];\n")
PY

cd "$crate"
cargo test --locked -p tablepro-keys --lib vectors::write_vectors -- --ignored --exact
