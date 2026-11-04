use aes::Aes256;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cbc::cipher::block_padding::Pkcs7;
use cbc::cipher::{BlockDecryptMut, KeyIvInit};
use serde_json::Value;
use sha2::{Digest, Sha256};

// Beekeeper's built-in key, which only unwraps the per-install key saved in `.key`.
pub(super) const DEFAULT_KEY: &str = "38782F413F442A472D4B6150645367566B59703373367639792442264529482B";

const HMAC_HEX_LEN: usize = 64;
const IV_END: usize = HMAC_HEX_LEN + 32;

// The HMAC goes unchecked, as on macOS: a tampered value fails the padding or the JSON instead.
pub(super) fn decrypt(payload: &str, key: &str) -> Option<Value> {
    if payload.len() <= IV_END {
        return None;
    }
    let iv = hex::decode(payload.get(HMAC_HEX_LEN..IV_END)?).ok()?;
    let ciphertext = STANDARD.decode(payload.get(IV_END..)?).ok()?;
    let key = Sha256::digest(key.as_bytes());
    let plaintext = cbc::Decryptor::<Aes256>::new_from_slices(key.as_slice(), &iv)
        .ok()?
        .decrypt_padded_vec_mut::<Pkcs7>(&ciphertext)
        .ok()?;
    serde_json::from_slice(&plaintext).ok()
}

pub(super) fn decrypt_string(payload: &str, key: &str) -> Option<String> {
    match decrypt(payload, key)? {
        Value::String(text) => Some(text),
        _ => None,
    }
}

// The `.key` file holds `{"encryptionKey": "<hex>"}`, and the hex string itself is the key, not its bytes.
pub(super) fn decrypt_key_file(payload: &str) -> Option<String> {
    decrypt(payload, DEFAULT_KEY)?
        .get("encryptionKey")?
        .as_str()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Written by Node's crypto in simple-encryptor's format, with a real HMAC.
    const HUNTER2: &str = "1b8a4e2e1f4f66f7f01614a09bc8d12e811f1ab3163882fba392e32e6b4a73fd1af13ccffa292e0ff6a1500816bdab2aCzPG8sqlqQ6/7OGE6av2Ww==";
    const KEY_FILE_ABC123: &str = "d01ab48cdf500e249b7647f64bca32a58fd7521d7f77e8a08485285b1c30e5731eedd684c281ce4bb789154769bfcdaeMGgzH+wBKu/Q2coJZb6jbyLCcZC2T1YHvU/fezI6YAw=";
    const SECRET: &str = "f2bb59a5206b8efc899e75bf17dc364f1659f3b1b70eb51ceaab9b6f65efc430ad86947f6ef7eeebe620d49d15fa3310mjl17u3p+aQuSg1zIkt9+w==";
    const NUMBER_42: &str = "d58456133b51bcbe5c0cc0b451bb5bcf5e1f72224d127c2bc27c026fd2db0f44dd2aa8155448c03be212f203a5ccdb4ajYEGViiM8CN5OUT+8MImfw==";

    #[test]
    fn a_string_encrypted_by_simple_encryptor_decrypts() {
        assert_eq!(
            decrypt_string(HUNTER2, "user-key-1234567890").as_deref(),
            Some("hunter2")
        );
    }

    #[test]
    fn a_dictionary_encrypted_by_simple_encryptor_decrypts() {
        let decoded = decrypt(KEY_FILE_ABC123, DEFAULT_KEY).expect("a value");
        assert_eq!(decoded.get("encryptionKey").and_then(Value::as_str), Some("abc123"));
        assert_eq!(decrypt_key_file(KEY_FILE_ABC123).as_deref(), Some("abc123"));
    }

    #[test]
    fn a_malformed_payload_decrypts_to_nothing() {
        assert_eq!(decrypt("too-short", "any"), None);
        assert_eq!(decrypt(&"z".repeat(200), "any"), None);
        let bad_base64 = format!("{}{}", &HUNTER2[..IV_END], "not base64!");
        assert_eq!(decrypt(&bad_base64, "user-key-1234567890"), None);
    }

    #[test]
    fn the_wrong_key_decrypts_to_nothing() {
        assert_eq!(decrypt_string(SECRET, "wrong-key"), None);
        assert_eq!(decrypt_string(SECRET, "correct-key").as_deref(), Some("secret"));
    }

    #[test]
    fn a_value_of_another_type_is_neither_a_password_nor_a_key_file() {
        assert_eq!(decrypt(NUMBER_42, "user-key-1234567890"), Some(Value::from(42)));
        assert_eq!(decrypt_string(NUMBER_42, "user-key-1234567890"), None);
        assert_eq!(decrypt_key_file(HUNTER2), None);
    }

    #[test]
    fn the_hmac_is_not_checked() {
        let tampered = format!("{}{}", "0".repeat(HMAC_HEX_LEN), &HUNTER2[HMAC_HEX_LEN..]);
        assert_eq!(
            decrypt_string(&tampered, "user-key-1234567890").as_deref(),
            Some("hunter2")
        );
    }
}
