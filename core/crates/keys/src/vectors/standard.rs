// RFC 9180's vectors for (0x0020, 0x0001, 0x0002) and Wycheproof's for AES-GCM, X25519, Ed25519 and
// HKDF-SHA256, run through the crate's own calls (ADR 0056, Vectors, Standard).

use rustls::crypto::aws_lc_rs::hpke::DH_KEM_X25519_HKDF_SHA256_AES_256;
use rustls::crypto::hpke::{EncapsulatedSecret, Hpke as _, HpkePrivateKey};

use crate::KeysError;
use crate::crypto;
use crate::json::{JsonValue, Members, as_str};

fn load(name: &str) -> JsonValue {
    let path = super::dir().join("standard").join(name);
    let bytes = std::fs::read(&path).unwrap_or_else(|_| panic!("{} is missing", path.display()));
    let file = crate::json::parse(&bytes).expect("standard vectors parse");
    let mut members = Members::of(&file).expect("object");
    members.required("vectors").expect("vectors").clone()
}

fn member<'a>(value: &'a JsonValue, name: &str) -> &'a JsonValue {
    match value {
        JsonValue::Object(members) => members
            .iter()
            .find(|(member, _)| member == name)
            .map(|(_, value)| value)
            .unwrap_or_else(|| panic!("no {name}")),
        _ => panic!("not an object"),
    }
}

fn text<'a>(value: &'a JsonValue, name: &str) -> &'a str {
    as_str(member(value, name)).expect("string")
}

fn bytes(value: &JsonValue, name: &str) -> Vec<u8> {
    hex::decode(text(value, name)).expect("hex")
}

fn items(value: &JsonValue) -> &[JsonValue] {
    match value {
        JsonValue::Array(items) => items,
        _ => panic!("not an array"),
    }
}

fn number(value: &JsonValue, name: &str) -> u64 {
    match member(value, name) {
        JsonValue::Number(number) => number.as_u64().expect("unsigned"),
        _ => panic!("{name} is not a number"),
    }
}

fn array32(bytes: &[u8]) -> [u8; 32] {
    bytes.try_into().expect("32 bytes")
}

#[test]
fn rfc_9180_vectors_open_through_the_suite() {
    let entries = load("rfc9180.json");
    assert_eq!(items(&entries).len(), 4, "one entry per mode");
    let mut opened = 0;
    for entry in items(&entries) {
        let sk_r = array32(&bytes(entry, "skRm"));
        assert_eq!(crypto::x25519_public(&sk_r).unwrap().to_vec(), bytes(entry, "pkRm"));
        let sk_e = array32(&bytes(entry, "skEm"));
        assert_eq!(crypto::x25519_public(&sk_e).unwrap().to_vec(), bytes(entry, "pkEm"));
        assert_eq!(bytes(entry, "enc"), bytes(entry, "pkEm"));
        // rustls implements base mode, the only one tp1 uses.
        if number(entry, "mode") != 0 {
            continue;
        }
        let enc = array32(&bytes(entry, "enc"));
        let info = bytes(entry, "info");
        let encryptions = items(member(entry, "encryptions"));
        let first = &encryptions[0];
        if bytes(first, "aad").is_empty() {
            assert_eq!(
                crypto::hpke_open(&sk_r, &enc, &info, &bytes(first, "ct"))
                    .unwrap()
                    .as_slice(),
                bytes(first, "pt").as_slice()
            );
        }
        let mut opener = DH_KEM_X25519_HKDF_SHA256_AES_256
            .setup_opener(
                &EncapsulatedSecret(enc.to_vec()),
                &info,
                &HpkePrivateKey::from(sk_r.to_vec()),
            )
            .unwrap();
        for encryption in encryptions {
            assert_eq!(
                opener
                    .open(&bytes(encryption, "aad"), &bytes(encryption, "ct"))
                    .unwrap(),
                bytes(encryption, "pt")
            );
            opened += 1;
        }
        let mut tampered = bytes(first, "ct");
        tampered[0] ^= 1;
        assert_eq!(
            crypto::hpke_open(&sk_r, &enc, &info, &tampered).unwrap_err(),
            KeysError::Open
        );
    }
    assert!(opened > 0);
}

#[test]
fn wycheproof_aes_gcm() {
    let file = load("wycheproof_aes_gcm.json");
    let mut count = 0;
    for group in items(member(&file, "testGroups")) {
        for test in items(member(group, "tests")) {
            let key = array32(&bytes(test, "key"));
            let nonce: [u8; 12] = bytes(test, "iv").try_into().expect("nonce");
            let aad = bytes(test, "aad");
            let sealed = [bytes(test, "ct"), bytes(test, "tag")].concat();
            let opened = crypto::aes_open(&key, &nonce, &aad, &sealed);
            match text(test, "result") {
                "valid" => {
                    assert_eq!(
                        opened.unwrap().as_slice(),
                        bytes(test, "msg").as_slice(),
                        "tcId {}",
                        number(test, "tcId")
                    );
                    assert_eq!(
                        crypto::aes_seal(&key, &nonce, &aad, &bytes(test, "msg")).unwrap(),
                        sealed
                    );
                }
                _ => assert!(opened.is_err(), "tcId {}", number(test, "tcId")),
            }
            count += 1;
        }
    }
    assert!(count > 50);
}

#[test]
fn wycheproof_x25519() {
    let file = load("wycheproof_x25519.json");
    let mut count = 0;
    for group in items(member(&file, "testGroups")) {
        for test in items(member(group, "tests")) {
            let id = number(test, "tcId");
            let shared = bytes(test, "shared");
            let agreed = crypto::x25519_agree(&array32(&bytes(test, "private")), &array32(&bytes(test, "public")));
            if shared.iter().all(|byte| *byte == 0) {
                // RFC 9180 section 7.1.4: an all-zero shared secret is refused.
                assert_eq!(agreed.unwrap_err(), KeysError::PublicKey, "tcId {id}");
            } else {
                assert_eq!(agreed.unwrap().as_slice(), shared.as_slice(), "tcId {id}");
            }
            count += 1;
        }
    }
    assert!(count > 500);
}

#[test]
fn wycheproof_ed25519() {
    let file = load("wycheproof_ed25519.json");
    let mut count = 0;
    let mut acceptable = 0;
    for group in items(member(&file, "testGroups")) {
        let public = array32(&bytes(member(group, "publicKey"), "pk"));
        for test in items(member(group, "tests")) {
            let id = number(test, "tcId");
            let signature = bytes(test, "sig");
            let verified = <[u8; 64]>::try_from(signature.as_slice())
                .map_err(|_| KeysError::Signature)
                .and_then(|signature| crypto::ed25519_verify(&public, &bytes(test, "msg"), &signature));
            match text(test, "result") {
                "valid" => assert_eq!(verified, Ok(()), "tcId {id}"),
                "invalid" => assert_eq!(verified, Err(KeysError::Signature), "tcId {id}"),
                // tcIds 152 to 159 are forgeries under a key of small order, which the library takes and
                // ADR 0056 refuses before it; 160 to 180 hold the cofactorless equation under a key of
                // mixed order, which no rule refuses.
                _ => {
                    let library = <[u8; 64]>::try_from(signature.as_slice()).is_ok_and(|signature| {
                        crypto::forgery::library_accepts(&public, &bytes(test, "msg"), &signature)
                    });
                    assert!(library, "tcId {id}");
                    match id {
                        152..=159 => assert_eq!(verified, Err(KeysError::Signature), "tcId {id}"),
                        160..=180 => assert_eq!(verified, Ok(()), "tcId {id}"),
                        _ => panic!("tcId {id} is acceptable and has no tp1 outcome"),
                    }
                    acceptable += 1;
                }
            }
            count += 1;
        }
    }
    assert!(count > 100);
    assert_eq!(acceptable, 29);
}

#[test]
fn wycheproof_hkdf_sha256() {
    let file = load("wycheproof_hkdf_sha256.json");
    let mut count = 0;
    for group in items(member(&file, "testGroups")) {
        for test in items(member(group, "tests")) {
            let id = number(test, "tcId");
            let derived = crypto::hkdf(
                &bytes(test, "salt"),
                &bytes(test, "ikm"),
                &bytes(test, "info"),
                usize::try_from(number(test, "size")).expect("size"),
            );
            match text(test, "result") {
                "valid" => assert_eq!(derived.unwrap().as_slice(), bytes(test, "okm").as_slice(), "tcId {id}"),
                _ => assert!(derived.is_err(), "tcId {id}"),
            }
            count += 1;
        }
    }
    assert!(count > 50);
    // `salt = none` is HashLen zeros (RFC 5869 section 2.2), the same key to HMAC as an empty one.
    assert_eq!(
        crypto::hkdf(&[], b"ikm", b"info", 32).unwrap(),
        crypto::hkdf(&[0; 32], b"ikm", b"info", 32).unwrap()
    );
}
