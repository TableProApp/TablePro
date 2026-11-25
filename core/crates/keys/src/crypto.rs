// Calls into aws-lc-rs, and HPKE through rustls's aws-lc-rs module (ADR 0056, Libraries). No
// primitive lives here; the Ed25519 checks are range and table comparisons before the library verifies.

use aws_lc_rs::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use aws_lc_rs::agreement::{self, UnparsedPublicKey, X25519};
use aws_lc_rs::digest::{SHA256, digest};
use aws_lc_rs::hkdf::{HKDF_SHA256, KeyType, Salt};
use aws_lc_rs::hmac;
use aws_lc_rs::signature::{ED25519, Ed25519KeyPair, KeyPair as _};
use rustls::crypto::aws_lc_rs::hpke::DH_KEM_X25519_HKDF_SHA256_AES_256;
use rustls::crypto::hpke::{EncapsulatedSecret, Hpke as _, HpkePrivateKey, HpkePublicKey};
use zeroize::Zeroizing;

use crate::KeysError;

pub(crate) const NONCE_LEN: usize = 12;
pub(crate) const TAG_LEN: usize = 16;

pub(crate) fn random(bytes: &mut [u8]) -> Result<(), KeysError> {
    aws_lc_rs::rand::fill(bytes).map_err(|_| KeysError::Random)
}

pub(crate) fn random_array<const N: usize>() -> Result<[u8; N], KeysError> {
    let mut bytes = [0_u8; N];
    random(&mut bytes)?;
    Ok(bytes)
}

pub(crate) fn sha256(input: &[u8]) -> [u8; 32] {
    let mut out = [0_u8; 32];
    out.copy_from_slice(digest(&SHA256, input).as_ref());
    out
}

struct Len(usize);

impl KeyType for Len {
    fn len(&self) -> usize {
        self.0
    }
}

// HKDF-SHA256 (RFC 5869). An absent salt is RFC 5869's string of HashLen zeros, which HMAC
// treats the same as an empty key.
pub(crate) fn hkdf(salt: &[u8], ikm: &[u8], info: &[u8], len: usize) -> Result<Zeroizing<Vec<u8>>, KeysError> {
    let prk = Salt::new(HKDF_SHA256, salt).extract(ikm);
    let info = [info];
    let okm = prk
        .expand(&info, Len(len))
        .map_err(|_| KeysError::encoding("HKDF output too long"))?;
    let mut out = Zeroizing::new(vec![0_u8; len]);
    okm.fill(&mut out)
        .map_err(|_| KeysError::encoding("HKDF output too long"))?;
    Ok(out)
}

// HKDF-SHA256 with no salt and L = 32, as every derivation in ADR 0056 is.
pub(crate) fn hkdf32(ikm: &[u8], info: &[u8]) -> Result<Zeroizing<[u8; 32]>, KeysError> {
    let okm = hkdf(&[], ikm, info, 32)?;
    let mut out = Zeroizing::new([0_u8; 32]);
    out.copy_from_slice(&okm);
    Ok(out)
}

pub(crate) fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let key = hmac::Key::new(hmac::HMAC_SHA256, key);
    let mut out = [0_u8; 32];
    out.copy_from_slice(hmac::sign(&key, message).as_ref());
    out
}

fn aes_key(key: &[u8; 32]) -> Result<LessSafeKey, KeysError> {
    UnboundKey::new(&AES_256_GCM, key)
        .map(LessSafeKey::new)
        .map_err(|_| KeysError::encoding("AES-256 key"))
}

// AES-256-GCM: the ciphertext followed by its 16-byte tag.
pub(crate) fn aes_seal(
    key: &[u8; 32],
    nonce: &[u8; NONCE_LEN],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, KeysError> {
    let mut in_out = plaintext.to_vec();
    aes_key(key)?
        .seal_in_place_append_tag(Nonce::assume_unique_for_key(*nonce), Aad::from(aad), &mut in_out)
        .map_err(|_| KeysError::encoding("plaintext too long for AES-GCM"))?;
    Ok(in_out)
}

pub(crate) fn aes_open(
    key: &[u8; 32],
    nonce: &[u8; NONCE_LEN],
    aad: &[u8],
    ciphertext: &[u8],
) -> Result<Zeroizing<Vec<u8>>, KeysError> {
    if ciphertext.len() < TAG_LEN {
        return Err(KeysError::encoding("ciphertext shorter than its tag"));
    }
    let mut in_out = Zeroizing::new(ciphertext.to_vec());
    let len = aes_key(key)?
        .open_in_place(Nonce::assume_unique_for_key(*nonce), Aad::from(aad), &mut in_out)
        .map_err(|_| KeysError::Open)?
        .len();
    in_out.truncate(len);
    Ok(in_out)
}

// The eight points of small order, canonically encoded (Chalkias, Garillot and Nikolaenko, 2020).
const SMALL_ORDER: [[u8; 32]; 8] = [
    hex32("0100000000000000000000000000000000000000000000000000000000000000"),
    hex32("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
    hex32("0000000000000000000000000000000000000000000000000000000000000000"),
    hex32("0000000000000000000000000000000000000000000000000000000000000080"),
    hex32("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"),
    hex32("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa"),
    hex32("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05"),
    hex32("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85"),
];

// p = 2^255 - 19 and L = 2^252 + 27742317777372353535851937790883648493, little-endian.
const FIELD_P: [u8; 32] = hex32("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f");
const GROUP_L: [u8; 32] = hex32("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");

const fn hex32(text: &str) -> [u8; 32] {
    let bytes = text.as_bytes();
    let mut out = [0_u8; 32];
    let mut index = 0;
    while index < 32 {
        out[index] = (nibble(bytes[2 * index]) << 4) | nibble(bytes[2 * index + 1]);
        index += 1;
    }
    out
}

const fn nibble(byte: u8) -> u8 {
    match byte {
        b'0'..=b'9' => byte - b'0',
        b'a'..=b'f' => byte - b'a' + 10,
        _ => 0,
    }
}

// a < b, both little-endian.
fn less_than(a: &[u8; 32], b: &[u8; 32]) -> bool {
    for index in (0..32).rev() {
        if a[index] != b[index] {
            return a[index] < b[index];
        }
    }
    false
}

// y below p, with the sign bit cleared.
fn canonical_point(encoding: &[u8; 32]) -> bool {
    let mut y = *encoding;
    y[31] &= 0x7f;
    less_than(&y, &FIELD_P)
}

pub(crate) fn ed25519_public(seed: &[u8; 32]) -> Result<[u8; 32], KeysError> {
    let pair = Ed25519KeyPair::from_seed_unchecked(seed).map_err(|_| KeysError::encoding("Ed25519 seed"))?;
    let mut out = [0_u8; 32];
    out.copy_from_slice(pair.public_key().as_ref());
    Ok(out)
}

pub(crate) fn ed25519_sign(seed: &[u8; 32], message: &[u8]) -> Result<[u8; 64], KeysError> {
    let pair = Ed25519KeyPair::from_seed_unchecked(seed).map_err(|_| KeysError::encoding("Ed25519 seed"))?;
    let signature = pair
        .try_sign(message)
        .map_err(|_| KeysError::encoding("Ed25519 signing failed"))?;
    let mut out = [0_u8; 64];
    out.copy_from_slice(signature.as_ref());
    Ok(out)
}

// ADR 0056, Libraries: refuse a non-canonical A or R, an A of small order and S at or above L,
// then verify cofactorless as the library does.
pub(crate) fn ed25519_verify(public: &[u8; 32], message: &[u8], signature: &[u8; 64]) -> Result<(), KeysError> {
    let mut r = [0_u8; 32];
    let mut s = [0_u8; 32];
    r.copy_from_slice(&signature[..32]);
    s.copy_from_slice(&signature[32..]);
    if !canonical_point(public) || SMALL_ORDER.contains(public) || !canonical_point(&r) || !less_than(&s, &GROUP_L) {
        return Err(KeysError::Signature);
    }
    aws_lc_rs::signature::UnparsedPublicKey::new(&ED25519, public)
        .verify(message, signature)
        .map_err(|_| KeysError::Signature)
}

pub(crate) fn x25519_public(secret: &[u8; 32]) -> Result<[u8; 32], KeysError> {
    let private =
        agreement::PrivateKey::from_private_key(&X25519, secret).map_err(|_| KeysError::encoding("X25519 key"))?;
    let public = private
        .compute_public_key()
        .map_err(|_| KeysError::encoding("X25519 key"))?;
    let mut out = [0_u8; 32];
    out.copy_from_slice(public.as_ref());
    Ok(out)
}

// aws-lc refuses an agreement whose shared secret is all zero, which is exactly a peer key of
// small order (RFC 9180 section 7.1.4).
pub(crate) fn x25519_agree(secret: &[u8; 32], peer: &[u8; 32]) -> Result<Zeroizing<[u8; 32]>, KeysError> {
    let private =
        agreement::PrivateKey::from_private_key(&X25519, secret).map_err(|_| KeysError::encoding("X25519 key"))?;
    agreement::agree(
        &private,
        UnparsedPublicKey::new(&X25519, peer),
        KeysError::PublicKey,
        |shared| {
            let mut out = Zeroizing::new([0_u8; 32]);
            if shared.len() != 32 {
                return Err(KeysError::PublicKey);
            }
            out.copy_from_slice(shared);
            Ok(out)
        },
    )
}

// HPKE base mode, single shot, suite (0x0020, 0x0001, 0x0002), with an empty aad (RFC 9180 section 6.1).
pub(crate) fn hpke_seal(recipient: &[u8; 32], info: &[u8], plaintext: &[u8]) -> Result<([u8; 32], Vec<u8>), KeysError> {
    let probe = Zeroizing::new(random_array::<32>()?);
    x25519_agree(&probe, recipient)?;
    let (enc, ct) = DH_KEM_X25519_HKDF_SHA256_AES_256
        .seal(info, &[], plaintext, &HpkePublicKey(recipient.to_vec()))
        .map_err(|_| KeysError::Random)?;
    let enc = <[u8; 32]>::try_from(enc.0.as_slice()).map_err(|_| KeysError::encoding("enc length"))?;
    Ok((enc, ct))
}

pub(crate) fn hpke_open(
    secret: &[u8; 32],
    enc: &[u8; 32],
    info: &[u8],
    ciphertext: &[u8],
) -> Result<Zeroizing<Vec<u8>>, KeysError> {
    x25519_agree(secret, enc)?;
    if ciphertext.len() < TAG_LEN {
        return Err(KeysError::encoding("ciphertext shorter than its tag"));
    }
    DH_KEM_X25519_HKDF_SHA256_AES_256
        .open(
            &EncapsulatedSecret(enc.to_vec()),
            info,
            &[],
            ciphertext,
            &HpkePrivateKey::from(secret.to_vec()),
        )
        .map(Zeroizing::new)
        .map_err(|_| KeysError::Open)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::{
        FIELD_P, GROUP_L, SMALL_ORDER, canonical_point, ed25519_public, ed25519_sign, ed25519_verify, less_than,
    };
    use crate::KeysError;

    #[test]
    fn the_constants_are_p_and_l() {
        let mut p_minus_one = FIELD_P;
        p_minus_one[0] -= 1;
        assert!(canonical_point(&p_minus_one));
        assert!(!canonical_point(&FIELD_P));
        assert!(less_than(&[0; 32], &GROUP_L));
        assert!(!less_than(&GROUP_L, &GROUP_L));
        assert_eq!(SMALL_ORDER.len(), 8);
    }

    #[test]
    fn ed25519_refusals_come_before_the_library() {
        let seed = [7_u8; 32];
        let public = ed25519_public(&seed).unwrap();
        let signature = ed25519_sign(&seed, b"m").unwrap();
        assert_eq!(ed25519_verify(&public, b"m", &signature), Ok(()));
        assert_eq!(ed25519_verify(&public, b"n", &signature), Err(KeysError::Signature));

        let mut high_s = signature;
        high_s[32..].copy_from_slice(&GROUP_L);
        assert_eq!(ed25519_verify(&public, b"m", &high_s), Err(KeysError::Signature));

        let mut bad_r = signature;
        bad_r[..32].copy_from_slice(&FIELD_P);
        assert_eq!(ed25519_verify(&public, b"m", &bad_r), Err(KeysError::Signature));

        for small in SMALL_ORDER {
            assert_eq!(ed25519_verify(&small, b"m", &signature), Err(KeysError::Signature));
        }
    }
}
