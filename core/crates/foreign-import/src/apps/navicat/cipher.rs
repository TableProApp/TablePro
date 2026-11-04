// The fixed-key ciphers of an .ncx export: github.com/HyperSine/how-does-navicat-encrypt-password

use aes::Aes128;
use blowfish::Blowfish;
use blowfish::cipher::generic_array::GenericArray;
use blowfish::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use cbc::cipher::block_padding::NoPadding;
use cbc::cipher::{BlockDecryptMut, KeyIvInit};
use sha1::{Digest, Sha1};

const AES_KEY: &[u8; 16] = b"libcckeylibcckey";
const AES_IV: &[u8; 16] = b"libcciv libcciv ";
const AES_BLOCK: usize = 16;
const BLOWFISH_KEY_SEED: &[u8] = b"3DC5CA39";
const BLOWFISH_BLOCK: usize = 8;

pub(super) fn decrypt(hex: &str) -> Option<String> {
    if hex.is_empty() {
        return None;
    }
    let ciphertext = hex::decode(hex).ok()?;
    decrypt_v2(&ciphertext)
        .filter(|value| is_plausible_text(value))
        .or_else(|| decrypt_v1(&ciphertext).filter(|value| is_plausible_text(value)))
}

fn is_plausible_text(value: &str) -> bool {
    !value.is_empty() && !value.chars().any(char::is_control)
}

// Navicat 12 and later: AES-128-CBC.
fn decrypt_v2(ciphertext: &[u8]) -> Option<String> {
    if ciphertext.is_empty() || !ciphertext.len().is_multiple_of(AES_BLOCK) {
        return None;
    }
    let mut buffer = ciphertext.to_vec();
    let length = cbc::Decryptor::<Aes128>::new(AES_KEY.into(), AES_IV.into())
        .decrypt_padded_mut::<NoPadding>(&mut buffer)
        .ok()?
        .len();
    buffer.truncate(length);
    // As CommonCrypto unpads for the macOS app: the last byte alone decides, and 0 or past a block strips nothing.
    if let Some(&pad) = buffer.last() {
        let pad = usize::from(pad);
        if (1..=AES_BLOCK).contains(&pad) {
            buffer.truncate(buffer.len().saturating_sub(pad));
        }
    }
    utf8_text(buffer)
}

// Navicat 11: Blowfish-ECB in a CBC-like XOR chain, the tail XORed with a keystream block.
fn decrypt_v1(ciphertext: &[u8]) -> Option<String> {
    if ciphertext.is_empty() {
        return None;
    }
    let cipher: Blowfish = Blowfish::new_from_slice(&Sha1::digest(BLOWFISH_KEY_SEED)).ok()?;
    let mut vector = [0xFF_u8; BLOWFISH_BLOCK];
    cipher.encrypt_block(GenericArray::from_mut_slice(&mut vector));

    let mut output = Vec::with_capacity(ciphertext.len());
    let (blocks, tail) = ciphertext.as_chunks::<BLOWFISH_BLOCK>();
    for block in blocks {
        let mut decrypted = *block;
        cipher.decrypt_block(GenericArray::from_mut_slice(&mut decrypted));
        output.extend(decrypted.iter().zip(&vector).map(|(byte, mask)| byte ^ mask));
        vector.iter_mut().zip(block).for_each(|(mask, byte)| *mask ^= byte);
    }

    if !tail.is_empty() {
        let mut keystream = vector;
        cipher.encrypt_block(GenericArray::from_mut_slice(&mut keystream));
        output.extend(tail.iter().zip(&keystream).map(|(byte, mask)| byte ^ mask));
    }
    utf8_text(output)
}

// Foundation drops one leading byte order mark when it decodes UTF-8.
fn utf8_text(bytes: Vec<u8>) -> Option<String> {
    let text = String::from_utf8(bytes).ok()?;
    Some(match text.strip_prefix('\u{FEFF}') {
        Some(rest) => rest.to_owned(),
        None => text,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decrypts_a_navicat_12_aes_password() {
        assert_eq!(
            decrypt("B75D320B6211468D63EB3B67C9E85933").as_deref(),
            Some("This is a test")
        );
        assert_eq!(
            decrypt("b75d320b6211468d63eb3b67c9e85933").as_deref(),
            Some("This is a test")
        );
    }

    #[test]
    fn decrypts_a_navicat_11_blowfish_password() {
        assert_eq!(
            decrypt("0EA71F51DD37BFB60CCBA219BE3A").as_deref(),
            Some("This is a test")
        );
    }

    #[test]
    fn decrypts_a_navicat_11_password_whose_length_is_a_multiple_of_the_aes_block() {
        assert_eq!(
            decrypt("2E6C8CF471EB0268D3239A0AD531F1B1").as_deref(),
            Some("Sup3rSecret!Pass")
        );
    }

    #[test]
    fn decrypts_multibyte_text() {
        assert_eq!(
            decrypt("539E5461C296451492DD78894233BE0DB9292731D8497E89821698B21B2F7CCF").as_deref(),
            Some("mật khẩu🔑")
        );
    }

    #[test]
    fn padding_is_read_as_common_crypto_reads_it() {
        // "ABCDEFGHIJKLMN" + 0x41 0x02: only the last byte is a valid pad.
        assert_eq!(
            decrypt("16BF1E24F06B2B6CF645505368F03156").as_deref(),
            Some("ABCDEFGHIJKLMN")
        );
    }

    #[test]
    fn a_leading_byte_order_mark_is_dropped() {
        assert_eq!(decrypt("0284E3E4F7E77AD6A46C6D4242B0D660").as_deref(), Some("secret"));
    }

    #[test]
    fn a_password_with_a_control_character_is_not_plausible() {
        // "line\nbreak" under AES; Blowfish of the same bytes is not text either.
        assert_eq!(decrypt("D118EB44C0B5AC5E840CA6293D42E042"), None);
    }

    #[test]
    fn returns_nothing_for_an_empty_string() {
        assert_eq!(decrypt(""), None);
    }

    #[test]
    fn returns_nothing_for_odd_length_hex() {
        assert_eq!(decrypt("ABC"), None);
    }

    #[test]
    fn returns_nothing_for_non_hex_input() {
        assert_eq!(decrypt("ZZZZ"), None);
    }
}
