use chacha20::ChaCha20;
use salsa20::Salsa20;
use salsa20::cipher::{KeyIvInit, StreamCipher};
use sha2::{Digest, Sha256, Sha512};

const KEEPASS_SALSA20_NONCE: [u8; 8] = [0xe8, 0x30, 0x09, 0x4b, 0x97, 0x20, 0x5d, 0x2a];

// One keystream runs across every protected value of a file, in document order.
pub(crate) enum InnerStreamCipher {
    Salsa20(Box<Salsa20>),
    ChaCha20(Box<ChaCha20>),
}

impl InnerStreamCipher {
    pub(crate) fn for_stream(id: u32, stream_key: &[u8]) -> Option<Self> {
        match id {
            2 => Salsa20::new_from_slices(&Sha256::digest(stream_key), &KEEPASS_SALSA20_NONCE)
                .ok()
                .map(|cipher| Self::Salsa20(Box::new(cipher))),
            3 => {
                let digest = Sha512::digest(stream_key);
                Self::chacha20(&digest[..32], &digest[32..44])
            }
            _ => {
                tracing::warn!(id, "unsupported KDBX inner stream, protected values stay unread");
                None
            }
        }
    }

    pub(crate) fn chacha20(key: &[u8], nonce: &[u8]) -> Option<Self> {
        ChaCha20::new_from_slices(key, nonce)
            .ok()
            .map(|cipher| Self::ChaCha20(Box::new(cipher)))
    }

    pub(crate) fn process(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        let mut output = data.to_vec();
        let applied = match self {
            Self::Salsa20(cipher) => cipher.try_apply_keystream(&mut output),
            Self::ChaCha20(cipher) => cipher.try_apply_keystream(&mut output),
        };
        applied.ok().map(|()| output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keystream(cipher: &mut InnerStreamCipher, count: usize) -> Vec<u8> {
        cipher.process(&vec![0; count]).expect("a keystream")
    }

    #[test]
    fn chacha20_matches_the_rfc_8439_keystream_block_0() {
        let mut cipher = InnerStreamCipher::chacha20(&[0; 32], &[0; 12]).expect("a cipher");
        let expected = hex::decode(concat!(
            "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7",
            "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586"
        ))
        .expect("hex");
        assert_eq!(keystream(&mut cipher, 64), expected);
    }

    #[test]
    fn chacha20_matches_the_rfc_8439_keystream_block_1() {
        let mut cipher = InnerStreamCipher::chacha20(&[0; 32], &[0; 12]).expect("a cipher");
        let expected = hex::decode(concat!(
            "9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed",
            "29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f"
        ))
        .expect("hex");
        assert_eq!(keystream(&mut cipher, 128)[64..], expected);
    }

    #[test]
    fn processing_twice_with_the_same_key_gives_the_plaintext_back() {
        let key: Vec<u8> = (0..32).collect();
        let nonce: Vec<u8> = (0..12).collect();
        let plaintext = b"the quick brown fox";
        let mut encrypt = InnerStreamCipher::chacha20(&key, &nonce).expect("a cipher");
        let ciphertext = encrypt.process(plaintext).expect("ciphertext");
        let mut decrypt = InnerStreamCipher::chacha20(&key, &nonce).expect("a cipher");
        assert_eq!(decrypt.process(&ciphertext).expect("plaintext"), plaintext);
    }

    #[test]
    fn the_keystream_continues_across_values_rather_than_restarting() {
        let mut whole = InnerStreamCipher::for_stream(3, b"stream key").expect("a cipher");
        let mut split = InnerStreamCipher::for_stream(3, b"stream key").expect("a cipher");
        let all = keystream(&mut whole, 100);
        let mut parts = keystream(&mut split, 30);
        parts.extend(keystream(&mut split, 70));
        assert_eq!(all, parts);
    }

    #[test]
    fn salsa20_matches_the_estream_256_bit_set_1_vector_0() {
        let mut key = [0; 32];
        key[0] = 0x80;
        let mut cipher = Salsa20::new_from_slices(&key, &[0; 8]).expect("a cipher");
        let mut block = vec![0; 64];
        cipher.apply_keystream(&mut block);
        let expected = hex::decode(concat!(
            "e3be8fdd8beca2e3ea8ef9475b29a6e7003951e1097a5c38d23b7a5fad9f6844",
            "b22c97559e2723c7cbbd3fe4fc8d9a0744652a83e72a9c461876af4d7ef1a117"
        ))
        .expect("hex");
        assert_eq!(block, expected);
    }

    #[test]
    fn an_unknown_stream_id_gives_no_cipher() {
        assert!(InnerStreamCipher::for_stream(1, b"key").is_none());
        assert!(InnerStreamCipher::for_stream(0, b"key").is_none());
    }
}
