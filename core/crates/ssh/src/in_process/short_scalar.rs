// OpenSSH writes a P-256 private scalar as an mpint without its leading zero bytes, so about one
// key in 256 holds it in 31 bytes or fewer, and ssh-key 0.7 refuses any under 32 (`MIN_SIZE` in
// its `private/ecdsa.rs`). This opens such a key file as OpenSSH does, until an ssh-key release
// reads it, which `identity`'s short-scalar test notices.

use russh::keys::ssh_encoding::pem::PemLabel;
use russh::keys::ssh_encoding::{self, Decode, DecodePem, Mpint, Reader};
use russh::keys::ssh_key::cipher::Tag;
use russh::keys::ssh_key::private::{EcdsaKeypair, EcdsaPrivateKey, KeypairData};
use russh::keys::ssh_key::public::{EcdsaPublicKey, KeyData};
use russh::keys::ssh_key::{self, Cipher, Kdf, PrivateKey};
use zeroize::Zeroizing;

const P256_SCALAR: usize = 32;

// What ssh-key fails with on such a key, encrypted or not.
pub(super) fn is_refusal(error: &russh::keys::Error) -> bool {
    matches!(
        error,
        russh::keys::Error::SshKey(ssh_key::Error::Encoding(ssh_encoding::Error::Length))
    )
}

// `None` unless `text` is an OpenSSH P-256 key with a short scalar that `passphrase` opens.
pub(super) fn decode(text: &str, passphrase: Option<&str>) -> Option<PrivateKey> {
    let file = KeyFile::decode_pem(text).ok()?;
    let KeyData::Ecdsa(EcdsaPublicKey::NistP256(point)) = &file.public else {
        return None;
    };
    let mut private = file.private;
    if file.cipher.is_some() {
        let (key, iv) = file.kdf.derive_key_and_iv(file.cipher, passphrase?).ok()?;
        file.cipher.decrypt(&key, &iv, &mut private, file.tag).ok()?;
    }
    let reader = &mut private.as_slice();
    // Unequal check words mean a wrong passphrase.
    if u32::decode(reader).ok()? != u32::decode(reader).ok()? {
        return None;
    }
    if String::decode(reader).ok()? != "ecdsa-sha2-nistp256"
        || String::decode(reader).ok()? != "nistp256"
        || Vec::<u8>::decode(reader).ok()? != point.as_bytes()
    {
        return None;
    }
    let scalar = Zeroizing::new(Mpint::decode(reader).ok()?);
    let digits = scalar.as_positive_bytes()?;
    if digits.is_empty() || digits.len() >= P256_SCALAR {
        return None;
    }
    let comment = String::decode(reader).ok()?;
    // OpenSSH pads to the cipher's block with 1, 2, 3 and so on.
    let padding = reader.remaining_len();
    if padding >= file.cipher.block_size() {
        return None;
    }
    let mut tail = Zeroizing::new(vec![0; padding]);
    reader.read(&mut tail).ok()?;
    if !tail.iter().copied().eq(1..=u8::try_from(padding).ok()?) {
        return None;
    }
    let mut bytes = Zeroizing::new([0_u8; P256_SCALAR]);
    bytes[P256_SCALAR - digits.len()..].copy_from_slice(digits);
    let keypair = EcdsaKeypair::NistP256 {
        public: *point,
        private: EcdsaPrivateKey::from(*bytes),
    };
    PrivateKey::new(KeypairData::from(keypair), comment).ok()
}

// The openssh-key-v1 file around the private key, which ssh-key reads only along with the key.
struct KeyFile {
    cipher: Cipher,
    kdf: Kdf,
    public: KeyData,
    private: Zeroizing<Vec<u8>>,
    tag: Option<Tag>,
}

impl PemLabel for KeyFile {
    const PEM_LABEL: &'static str = "OPENSSH PRIVATE KEY";
}

impl Decode for KeyFile {
    type Error = ssh_key::Error;

    fn decode(reader: &mut impl Reader) -> Result<Self, ssh_key::Error> {
        const MAGIC: &[u8] = b"openssh-key-v1\0";
        let mut magic = [0_u8; MAGIC.len()];
        reader.read(&mut magic)?;
        if magic != MAGIC {
            return Err(ssh_key::Error::FormatEncoding);
        }
        let cipher = Cipher::decode(reader)?;
        let kdf = Kdf::decode(reader)?;
        if usize::decode(reader)? != 1 {
            return Err(ssh_encoding::Error::Length.into());
        }
        let public = reader.read_prefixed(KeyData::decode)?;
        let private = Zeroizing::new(Vec::<u8>::decode(reader)?);
        let tag = if cipher.has_tag() {
            let mut tag = Tag::default();
            reader.read(&mut tag)?;
            Some(tag)
        } else {
            None
        };
        Ok(Self {
            cipher,
            kdf,
            public,
            private,
            tag,
        })
    }
}
