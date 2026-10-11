use argon2::{Algorithm, Argon2, Params, Version};
use aws_lc_rs::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use aws_lc_rs::rand::{SecureRandom, SystemRandom};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::connection_bundle::BundleError;

pub(crate) const KDF_ALGORITHM: &str = "argon2id";
pub(crate) const CIPHER_ALGORITHM: &str = "aes-256-gcm";

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;

const EXPORT_MEMORY_KIB: u32 = 131_072;
const EXPORT_ITERATIONS: u32 = 3;
const EXPORT_PARALLELISM: u32 = 1;

/// Accepted on import, checked before any derivation runs. An
/// unchecked `memory_kib` is a memory bomb, and an unchecked floor
/// lets an attacker hand back a bundle that is cheap to crack.
const MIN_MEMORY_KIB: u32 = 19_456;
const MAX_MEMORY_KIB: u32 = 1_048_576;
const MIN_ITERATIONS: u32 = 1;
const MAX_ITERATIONS: u32 = 16;
const MIN_PARALLELISM: u32 = 1;
const MAX_PARALLELISM: u32 = 4;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KdfHeader {
    pub algorithm: String,
    pub salt: String,
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CipherHeader {
    pub algorithm: String,
    pub nonce: String,
}

/// The envelope fields an attacker must not be able to rewrite. They
/// are bound to the ciphertext through the AAD, so downgrading
/// `memory_kib` or swapping the producer invalidates the tag.
pub(crate) struct EnvelopeHeader {
    pub version: u32,
    pub producer: String,
    pub exported_at: String,
}

pub(crate) struct SealedBundle {
    pub kdf: KdfHeader,
    pub cipher: CipherHeader,
    pub ciphertext: Vec<u8>,
}

pub(crate) fn seal(plaintext: &[u8], passphrase: &str, envelope: &EnvelopeHeader) -> Result<SealedBundle, BundleError> {
    if passphrase.is_empty() {
        return Err(BundleError::EmptyPassphrase);
    }
    let rng = SystemRandom::new();
    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    rng.fill(&mut salt).map_err(|_| BundleError::EncryptionFailed)?;
    rng.fill(&mut nonce).map_err(|_| BundleError::EncryptionFailed)?;

    let kdf = KdfHeader {
        algorithm: KDF_ALGORITHM.to_owned(),
        salt: BASE64.encode(salt),
        memory_kib: EXPORT_MEMORY_KIB,
        iterations: EXPORT_ITERATIONS,
        parallelism: EXPORT_PARALLELISM,
    };
    let cipher = CipherHeader {
        algorithm: CIPHER_ALGORITHM.to_owned(),
        nonce: BASE64.encode(nonce),
    };
    let key = derive_key(passphrase, &salt, &kdf)?;
    let aad = associated_data(envelope, &kdf, &salt, &nonce);

    let unbound = UnboundKey::new(&AES_256_GCM, key.as_slice()).map_err(|_| BundleError::EncryptionFailed)?;
    let sealing = LessSafeKey::new(unbound);
    let mut ciphertext = plaintext.to_vec();
    sealing
        .seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::from(&aad), &mut ciphertext)
        .map_err(|_| BundleError::EncryptionFailed)?;

    Ok(SealedBundle {
        kdf,
        cipher,
        ciphertext,
    })
}

pub(crate) fn open(
    sealed: &SealedBundle,
    passphrase: &str,
    envelope: &EnvelopeHeader,
) -> Result<Zeroizing<Vec<u8>>, BundleError> {
    if passphrase.is_empty() {
        return Err(BundleError::EmptyPassphrase);
    }
    if sealed.kdf.algorithm != KDF_ALGORITHM || sealed.cipher.algorithm != CIPHER_ALGORITHM {
        return Err(BundleError::KdfParameters);
    }
    let salt = decode_fixed::<SALT_LEN>(&sealed.kdf.salt)?;
    let nonce = decode_fixed::<NONCE_LEN>(&sealed.cipher.nonce)?;
    let key = derive_key(passphrase, &salt, &sealed.kdf)?;
    let aad = associated_data(envelope, &sealed.kdf, &salt, &nonce);

    let unbound = UnboundKey::new(&AES_256_GCM, key.as_slice()).map_err(|_| BundleError::DecryptionFailed)?;
    let opening = LessSafeKey::new(unbound);
    let mut buffer = Zeroizing::new(sealed.ciphertext.clone());
    let plaintext_len = opening
        .open_in_place(
            Nonce::assume_unique_for_key(nonce),
            Aad::from(&aad),
            buffer.as_mut_slice(),
        )
        .map_err(|_| BundleError::DecryptionFailed)?
        .len();
    buffer.truncate(plaintext_len);
    Ok(buffer)
}

fn derive_key(passphrase: &str, salt: &[u8], kdf: &KdfHeader) -> Result<Zeroizing<[u8; KEY_LEN]>, BundleError> {
    check_kdf_parameters(kdf)?;
    let params = Params::new(kdf.memory_kib, kdf.iterations, kdf.parallelism, Some(KEY_LEN))
        .map_err(|_| BundleError::KdfParameters)?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(passphrase.as_bytes(), salt, key.as_mut_slice())
        .map_err(|_| BundleError::KdfParameters)?;
    Ok(key)
}

pub(crate) fn check_kdf_parameters(kdf: &KdfHeader) -> Result<(), BundleError> {
    if kdf.algorithm != KDF_ALGORITHM {
        return Err(BundleError::KdfParameters);
    }
    let in_range = (MIN_MEMORY_KIB..=MAX_MEMORY_KIB).contains(&kdf.memory_kib)
        && (MIN_ITERATIONS..=MAX_ITERATIONS).contains(&kdf.iterations)
        && (MIN_PARALLELISM..=MAX_PARALLELISM).contains(&kdf.parallelism);
    if !in_range {
        return Err(BundleError::KdfParameters);
    }
    decode_fixed::<SALT_LEN>(&kdf.salt)?;
    Ok(())
}

fn decode_fixed<const N: usize>(encoded: &str) -> Result<[u8; N], BundleError> {
    let raw = BASE64.decode(encoded).map_err(|_| BundleError::KdfParameters)?;
    raw.try_into().map_err(|_| BundleError::KdfParameters)
}

/// Additional authenticated data for the bundle seal. The layout is
/// fixed here rather than derived from the JSON because re-serializing
/// JSON is not byte-stable: `serde_json` runs with `preserve_order`,
/// so a rewritten document can reorder keys and break the tag.
///
/// `b"tablepro.connection-bundle\x00"` || u32_le(version)
///   || len(producer) || producer
///   || len(exported_at) || exported_at
///   || len("argon2id") || "argon2id" || salt
///   || u32_le(memory_kib) || u32_le(iterations) || u32_le(parallelism)
///   || len("aes-256-gcm") || "aes-256-gcm" || nonce
fn associated_data(envelope: &EnvelopeHeader, kdf: &KdfHeader, salt: &[u8], nonce: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(crate::connection_bundle::BUNDLE_FORMAT.as_bytes());
    out.push(0);
    out.extend_from_slice(&envelope.version.to_le_bytes());
    push_len_prefixed(&mut out, envelope.producer.as_bytes());
    push_len_prefixed(&mut out, envelope.exported_at.as_bytes());
    push_len_prefixed(&mut out, KDF_ALGORITHM.as_bytes());
    out.extend_from_slice(salt);
    out.extend_from_slice(&kdf.memory_kib.to_le_bytes());
    out.extend_from_slice(&kdf.iterations.to_le_bytes());
    out.extend_from_slice(&kdf.parallelism.to_le_bytes());
    push_len_prefixed(&mut out, CIPHER_ALGORITHM.as_bytes());
    out.extend_from_slice(nonce);
    out
}

fn push_len_prefixed(out: &mut Vec<u8>, bytes: &[u8]) {
    let len = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(bytes);
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_key_derivation_matches_the_value_released_builds_produce() {
        let salt = [7u8; SALT_LEN];
        let kdf = KdfHeader {
            algorithm: KDF_ALGORITHM.into(),
            salt: BASE64.encode(salt),
            memory_kib: 19_456,
            iterations: 2,
            parallelism: 1,
        };
        let key = derive_key("correct horse battery staple", &salt, &kdf).unwrap();
        let hex: String = key.iter().map(|byte| format!("{byte:02x}")).collect();
        assert_eq!(hex, "799f12b9e17710824482d829835acb69f5a9355bf774c4f07342823b11b90928");
    }

    use super::*;

    fn envelope() -> EnvelopeHeader {
        EnvelopeHeader {
            version: 1,
            producer: "bookie 0.2.0".into(),
            exported_at: "2026-09-19T10:00:00Z".into(),
        }
    }

    fn sealed(plaintext: &[u8]) -> SealedBundle {
        seal(plaintext, "correct horse", &envelope()).expect("seal")
    }

    #[test]
    fn a_sealed_body_opens_with_the_same_passphrase() {
        let body = b"{\"connections\":[]}";
        let bundle = sealed(body);
        let opened = open(&bundle, "correct horse", &envelope()).expect("open");
        assert_eq!(opened.as_slice(), body);
    }

    #[test]
    fn the_export_parameters_are_memory_hard() {
        let bundle = sealed(b"x");
        assert_eq!(bundle.kdf.algorithm, "argon2id");
        assert_eq!(bundle.kdf.memory_kib, EXPORT_MEMORY_KIB);
        assert!(bundle.kdf.memory_kib >= MIN_MEMORY_KIB);
        assert_eq!(bundle.cipher.algorithm, "aes-256-gcm");
    }

    #[test]
    fn every_seal_uses_a_fresh_salt_and_nonce() {
        let first = sealed(b"x");
        let second = sealed(b"x");
        assert_ne!(first.kdf.salt, second.kdf.salt);
        assert_ne!(first.cipher.nonce, second.cipher.nonce);
        assert_ne!(first.ciphertext, second.ciphertext);
    }

    #[test]
    fn a_wrong_passphrase_and_a_tampered_body_fail_the_same_way() {
        let bundle = sealed(b"{\"connections\":[]}");
        let wrong = open(&bundle, "wrong horse", &envelope()).unwrap_err();
        let mut tampered = SealedBundle {
            kdf: bundle.kdf.clone(),
            cipher: bundle.cipher.clone(),
            ciphertext: bundle.ciphertext.clone(),
        };
        tampered.ciphertext[0] ^= 0x01;
        let changed = open(&tampered, "correct horse", &envelope()).unwrap_err();
        assert!(matches!(wrong, BundleError::DecryptionFailed));
        assert!(matches!(changed, BundleError::DecryptionFailed));
        assert_eq!(wrong.to_string(), changed.to_string());
    }

    #[test]
    fn downgrading_the_kdf_header_cannot_produce_a_cheap_bundle() {
        let bundle = sealed(b"{\"connections\":[]}");
        let mut downgraded = SealedBundle {
            kdf: bundle.kdf.clone(),
            cipher: bundle.cipher.clone(),
            ciphertext: bundle.ciphertext.clone(),
        };
        downgraded.kdf.memory_kib = MIN_MEMORY_KIB;
        let error = open(&downgraded, "correct horse", &envelope()).unwrap_err();
        assert!(matches!(error, BundleError::DecryptionFailed));
    }

    #[test]
    fn rewriting_the_envelope_invalidates_the_tag() {
        let bundle = sealed(b"{\"connections\":[]}");
        let other = EnvelopeHeader {
            version: 1,
            producer: "attacker 9.9".into(),
            exported_at: "2026-09-19T10:00:00Z".into(),
        };
        assert!(matches!(
            open(&bundle, "correct horse", &other).unwrap_err(),
            BundleError::DecryptionFailed
        ));
    }

    #[test]
    fn a_memory_bomb_header_is_rejected_before_derivation() {
        let header = KdfHeader {
            algorithm: KDF_ALGORITHM.into(),
            salt: BASE64.encode([0u8; SALT_LEN]),
            memory_kib: u32::MAX,
            iterations: 3,
            parallelism: 1,
        };
        assert!(matches!(
            check_kdf_parameters(&header).unwrap_err(),
            BundleError::KdfParameters
        ));
    }

    #[test]
    fn kdf_parameters_outside_the_accepted_range_are_refused() {
        let base = KdfHeader {
            algorithm: KDF_ALGORITHM.into(),
            salt: BASE64.encode([0u8; SALT_LEN]),
            memory_kib: EXPORT_MEMORY_KIB,
            iterations: EXPORT_ITERATIONS,
            parallelism: EXPORT_PARALLELISM,
        };
        assert!(check_kdf_parameters(&base).is_ok());

        for mutate in [
            |h: &mut KdfHeader| h.memory_kib = MIN_MEMORY_KIB - 1,
            |h: &mut KdfHeader| h.memory_kib = MAX_MEMORY_KIB + 1,
            |h: &mut KdfHeader| h.iterations = 0,
            |h: &mut KdfHeader| h.iterations = MAX_ITERATIONS + 1,
            |h: &mut KdfHeader| h.parallelism = 0,
            |h: &mut KdfHeader| h.parallelism = MAX_PARALLELISM + 1,
            |h: &mut KdfHeader| h.algorithm = "pbkdf2".into(),
            |h: &mut KdfHeader| h.salt = BASE64.encode([0u8; 8]),
            |h: &mut KdfHeader| h.salt = "not base64!!".into(),
        ] {
            let mut header = base.clone();
            mutate(&mut header);
            assert!(
                matches!(check_kdf_parameters(&header), Err(BundleError::KdfParameters)),
                "accepted {header:?}"
            );
        }
    }

    #[test]
    fn an_empty_passphrase_is_refused_on_both_paths() {
        let bundle = sealed(b"x");
        assert!(matches!(seal(b"x", "", &envelope()), Err(BundleError::EmptyPassphrase)));
        assert!(matches!(
            open(&bundle, "", &envelope()).unwrap_err(),
            BundleError::EmptyPassphrase
        ));
    }

    #[test]
    fn the_associated_data_layout_is_length_prefixed_and_unambiguous() {
        let kdf = KdfHeader {
            algorithm: KDF_ALGORITHM.into(),
            salt: BASE64.encode([7u8; SALT_LEN]),
            memory_kib: 1,
            iterations: 2,
            parallelism: 3,
        };
        let first = associated_data(
            &EnvelopeHeader {
                version: 1,
                producer: "ab".into(),
                exported_at: "c".into(),
            },
            &kdf,
            &[7u8; SALT_LEN],
            &[9u8; NONCE_LEN],
        );
        let second = associated_data(
            &EnvelopeHeader {
                version: 1,
                producer: "a".into(),
                exported_at: "bc".into(),
            },
            &kdf,
            &[7u8; SALT_LEN],
            &[9u8; NONCE_LEN],
        );
        assert_ne!(first, second);
        assert!(first.starts_with(b"tablepro.connection-bundle\0"));
    }
}
