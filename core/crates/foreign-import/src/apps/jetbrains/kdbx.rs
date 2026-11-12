// The KDBX 3.1 file (`c.kdbx`) the IDE writes when it keeps secrets in KeePass: AES-KDF over the
// main key, an AES-256-CBC body of hashed blocks, optionally gzipped XML, and protected values
// under an inner stream cipher.

use std::collections::HashMap;
use std::io::Read;

use aes::Aes256;
use aes::cipher::block_padding::Pkcs7;
use aes::cipher::{BlockDecryptMut, BlockEncrypt, KeyInit, KeyIvInit};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use flate2::read::GzDecoder;
use roxmltree::{Document, Node, NodeId};
use secrecy::SecretString;
use sha2::{Digest, Sha256};

use super::inner_stream::InnerStreamCipher;
use super::xml;

const SIGNATURE_1: u32 = 0x9AA2_D903;
const SIGNATURE_2: u32 = 0xB54B_FB67;
const MAXIMUM_VERSION: u32 = 0x0003_0000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KdbxError {
    MalformedHeader,
    UnsupportedVersion,
    WrongKey,
    CorruptedData,
}

#[derive(Debug, Clone)]
pub(crate) struct KdbxEntry {
    pub title: String,
    pub password: SecretString,
}

#[derive(Default)]
struct Header {
    main_seed: Vec<u8>,
    transform_seed: Vec<u8>,
    transform_rounds: u64,
    encryption_iv: Vec<u8>,
    protected_stream_key: Vec<u8>,
    stream_start_bytes: Vec<u8>,
    inner_stream_id: u32,
    compression: u32,
}

pub(crate) fn read(file: &[u8], main_key: &[u8]) -> Result<Vec<KdbxEntry>, KdbxError> {
    let (header, payload_offset) = parse_header(file)?;
    let final_key = derive_final_key(&header, main_key)?;
    let payload = file.get(payload_offset..).unwrap_or_default();
    let plaintext = aes256_cbc_decrypt(payload, &final_key, &header.encryption_iv).ok_or(KdbxError::CorruptedData)?;
    if plaintext.get(..32) != Some(header.stream_start_bytes.as_slice()) {
        return Err(KdbxError::WrongKey);
    }
    let deframed = dehash_blocks(plaintext.get(32..).unwrap_or_default()).ok_or(KdbxError::CorruptedData)?;
    let xml = if header.compression == 1 {
        gunzip(&deframed).unwrap_or_default()
    } else {
        deframed
    };
    if xml.is_empty() {
        return Err(KdbxError::CorruptedData);
    }
    let cipher = InnerStreamCipher::for_stream(header.inner_stream_id, &header.protected_stream_key);
    Ok(parse_entries(&xml, cipher))
}

fn parse_header(data: &[u8]) -> Result<(Header, usize), KdbxError> {
    if data.len() <= 12 || le_u32(data, 0) != Some(SIGNATURE_1) || le_u32(data, 4) != Some(SIGNATURE_2) {
        return Err(KdbxError::MalformedHeader);
    }
    let version = le_u32(data, 8).ok_or(KdbxError::MalformedHeader)?;
    if version & 0xFFFF_0000 > MAXIMUM_VERSION {
        return Err(KdbxError::UnsupportedVersion);
    }

    let mut header = Header::default();
    let mut position = 12;
    while position + 3 <= data.len() {
        let field_type = data.get(position).copied().ok_or(KdbxError::MalformedHeader)?;
        let length = usize::from(le_u16(data, position + 1).ok_or(KdbxError::MalformedHeader)?);
        position += 3;
        let field = data
            .get(position..position + length)
            .ok_or(KdbxError::MalformedHeader)?;
        position += length;
        // A numeric field shorter than its type is malformed, not read past its end.
        let malformed = KdbxError::MalformedHeader;
        match field_type {
            0 => return Ok((header, position)),
            3 => header.compression = le_u32(field, 0).ok_or(malformed)?,
            4 => header.main_seed = field.to_vec(),
            5 => header.transform_seed = field.to_vec(),
            6 => header.transform_rounds = le_u64(field).ok_or(malformed)?,
            7 => header.encryption_iv = field.to_vec(),
            8 => header.protected_stream_key = field.to_vec(),
            9 => header.stream_start_bytes = field.to_vec(),
            10 => header.inner_stream_id = le_u32(field, 0).ok_or(malformed)?,
            _ => {}
        }
    }
    Err(KdbxError::MalformedHeader)
}

// Far above what the IDE writes, and a second or two of work at most, so a crafted file cannot
// hold the import's worker for good.
const MAX_TRANSFORM_ROUNDS: u64 = 50_000_000;

fn derive_final_key(header: &Header, main_key: &[u8]) -> Result<Vec<u8>, KdbxError> {
    if header.transform_rounds > MAX_TRANSFORM_ROUNDS {
        return Err(KdbxError::MalformedHeader);
    }
    let composite = Sha256::digest(Sha256::digest(main_key));
    let transformed =
        aes_kdf(&composite, &header.transform_seed, header.transform_rounds).ok_or(KdbxError::CorruptedData)?;
    let mut hasher = Sha256::new();
    hasher.update(&header.main_seed);
    hasher.update(Sha256::digest(transformed));
    Ok(hasher.finalize().to_vec())
}

pub(super) fn aes_kdf(input: &[u8], seed: &[u8], rounds: u64) -> Option<[u8; 32]> {
    if input.len() != 32 || seed.len() != 32 {
        return None;
    }
    let cipher = Aes256::new_from_slice(seed).ok()?;
    let (first, second) = input.split_at(16);
    let mut blocks = [
        aes::Block::clone_from_slice(first),
        aes::Block::clone_from_slice(second),
    ];
    for _ in 0..rounds {
        cipher.encrypt_blocks(&mut blocks);
    }
    let mut output = [0; 32];
    output[..16].copy_from_slice(&blocks[0]);
    output[16..].copy_from_slice(&blocks[1]);
    Some(output)
}

fn aes256_cbc_decrypt(ciphertext: &[u8], key: &[u8], iv: &[u8]) -> Option<Vec<u8>> {
    if ciphertext.is_empty() || iv.len() != 16 {
        return None;
    }
    cbc::Decryptor::<Aes256>::new_from_slices(key, iv)
        .ok()?
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .ok()
}

fn dehash_blocks(data: &[u8]) -> Option<Vec<u8>> {
    let mut result = Vec::new();
    let mut position = 0;
    while position + 40 <= data.len() {
        let hash = data.get(position + 4..position + 36)?;
        let size = usize::try_from(le_u32(data, position + 36)?).ok()?;
        position += 40;
        if size == 0 {
            return Some(result);
        }
        let block = data.get(position..position.checked_add(size)?)?;
        if Sha256::digest(block).as_slice() != hash {
            return None;
        }
        result.extend_from_slice(block);
        position += size;
    }
    Some(result)
}

fn gunzip(data: &[u8]) -> Option<Vec<u8>> {
    let mut inflated = Vec::new();
    // A compressed body has the same cap as a file, so a small file cannot inflate without end.
    GzDecoder::new(data)
        .take(crate::files::MAX_FILE_BYTES + 1)
        .read_to_end(&mut inflated)
        .ok()?;
    if u64::try_from(inflated.len()).unwrap_or(u64::MAX) > crate::files::MAX_FILE_BYTES {
        return None;
    }
    Some(inflated)
}

fn parse_entries(data: &[u8], cipher: Option<InnerStreamCipher>) -> Vec<KdbxEntry> {
    let Some(document) = xml::document(data) else {
        return Vec::new();
    };
    let decrypted = cipher
        .map(|cipher| decrypt_protected_values(&document, cipher))
        .unwrap_or_default();
    xml::elements(&document, "Entry")
        .map(|entry| parse_entry(entry, &decrypted))
        .collect()
}

fn is_protected(value: Node<'_, '_>) -> bool {
    value
        .attribute("Protected")
        .unwrap_or_default()
        .eq_ignore_ascii_case("true")
}

// Every protected value takes the next bytes of one keystream, so they are read in document order.
fn decrypt_protected_values(document: &Document<'_>, mut cipher: InnerStreamCipher) -> HashMap<NodeId, SecretString> {
    let mut values = HashMap::new();
    for value in xml::elements(document, "Value") {
        if !is_protected(value) {
            continue;
        }
        let Ok(encrypted) = STANDARD.decode(xml::text(value).trim()) else {
            continue;
        };
        let Some(plain) = cipher.process(&encrypted) else {
            continue;
        };
        values.insert(
            value.id(),
            SecretString::from(String::from_utf8(plain).unwrap_or_default()),
        );
    }
    values
}

fn parse_entry(entry: Node<'_, '_>, decrypted: &HashMap<NodeId, SecretString>) -> KdbxEntry {
    let mut title = String::new();
    let mut password = SecretString::from("");
    for string in entry
        .children()
        .filter(|child| child.is_element() && child.has_tag_name("String"))
    {
        let key = xml::child(string, "Key").map(xml::text).unwrap_or_default();
        let Some(value) = xml::child(string, "Value") else {
            continue;
        };
        match key.as_str() {
            "Title" => title = xml::text(value),
            "Password" => {
                password = match decrypted.get(&value.id()) {
                    Some(plain) => plain.clone(),
                    // A protected value that did not decrypt is ciphertext, never a password.
                    None if is_protected(value) => SecretString::from(""),
                    None => SecretString::from(xml::text(value)),
                };
            }
            _ => {}
        }
    }
    KdbxEntry { title, password }
}

fn le_u16(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn le_u32(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

fn le_u64(data: &[u8]) -> Option<u64> {
    Some(u64::from_le_bytes(data.get(..8)?.try_into().ok()?))
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;

    use super::super::test_kdbx::{self, InnerStream, KdbxOptions, TestEntry};
    use super::*;

    fn password_of<'a>(entries: &'a [KdbxEntry], title: &str) -> Option<&'a str> {
        entries
            .iter()
            .find(|entry| entry.title == title)
            .map(|entry| entry.password.expose_secret())
    }

    #[test]
    fn an_entry_is_read_and_its_chacha20_protected_password_decrypted() {
        let main_key = b"super-secret-main-key";
        let title = "IntelliJ Platform DB \u{2014} a1b2c3";
        let file = test_kdbx::make_kdbx(
            main_key,
            &[TestEntry::new(title, "dbuser", "p@ssw0rd!")],
            KdbxOptions::default(),
        );
        let entries = read(&file, main_key).expect("entries");
        assert_eq!(password_of(&entries, title), Some("p@ssw0rd!"));
    }

    #[test]
    fn a_protected_value_of_an_unknown_inner_stream_is_never_taken_as_the_password() {
        let main_key = b"unknown-stream-key";
        let title = "IntelliJ Platform DB \u{2014} unknown";
        let options = KdbxOptions {
            inner_stream: InnerStream::Unknown,
            ..KdbxOptions::default()
        };
        let file = test_kdbx::make_kdbx(main_key, &[TestEntry::new(title, "dbuser", "p@ssw0rd!")], options);
        let entries = read(&file, main_key).expect("entries");
        assert_eq!(password_of(&entries, title), Some(""));
    }

    #[test]
    fn a_gzip_compressed_payload_is_read() {
        let main_key = b"compressed-main-key";
        let title = "IntelliJ Platform DB \u{2014} gz";
        let options = KdbxOptions {
            compressed: true,
            ..KdbxOptions::default()
        };
        let file = test_kdbx::make_kdbx(main_key, &[TestEntry::new(title, "dbuser", "p@ssw0rd!")], options);
        let entries = read(&file, main_key).expect("entries");
        assert_eq!(password_of(&entries, title), Some("p@ssw0rd!"));
    }

    #[test]
    fn a_salsa20_inner_stream_decrypts_every_protected_value_in_document_order() {
        let main_key = b"salsa-main-key";
        let options = KdbxOptions {
            inner_stream: InnerStream::Salsa20,
            ..KdbxOptions::default()
        };
        let file = test_kdbx::make_kdbx(
            main_key,
            &[
                TestEntry::new("first", "u", "one"),
                TestEntry::new("second", "u", "two"),
            ],
            options,
        );
        let entries = read(&file, main_key).expect("entries");
        assert_eq!(password_of(&entries, "first"), Some("one"));
        assert_eq!(password_of(&entries, "second"), Some("two"));
    }

    #[test]
    fn the_wrong_main_key_is_rejected_by_the_stream_start_check() {
        let file = test_kdbx::make_kdbx(b"correct", &[TestEntry::new("t", "u", "p")], KdbxOptions::default());
        assert!(read(&file, b"incorrect").is_err());
    }

    #[test]
    fn a_malformed_signature_is_an_error() {
        assert_eq!(
            read(&[0x00, 0x01, 0x02, 0x03], &[]).err(),
            Some(KdbxError::MalformedHeader)
        );
    }

    #[test]
    fn a_key_derivation_past_the_round_limit_is_refused_before_any_work() {
        let header = Header {
            transform_rounds: MAX_TRANSFORM_ROUNDS + 1,
            ..Header::default()
        };
        assert_eq!(
            derive_final_key(&header, b"key").err(),
            Some(KdbxError::MalformedHeader)
        );
    }

    #[test]
    fn a_kdbx_4_file_is_unsupported() {
        let mut file = test_kdbx::make_kdbx(b"key", &[TestEntry::new("t", "u", "p")], KdbxOptions::default());
        file[8..12].copy_from_slice(&0x0004_0000_u32.to_le_bytes());
        assert_eq!(read(&file, b"key").err(), Some(KdbxError::UnsupportedVersion));
    }

    #[test]
    fn a_numeric_header_field_shorter_than_its_type_is_malformed() {
        let mut file = Vec::new();
        file.extend_from_slice(&SIGNATURE_1.to_le_bytes());
        file.extend_from_slice(&SIGNATURE_2.to_le_bytes());
        file.extend_from_slice(&0x0003_0001_u32.to_le_bytes());
        file.extend_from_slice(&[6, 2, 0, 0xff, 0xff]);
        file.extend_from_slice(&[0, 0, 0]);
        assert_eq!(read(&file, b"key").err(), Some(KdbxError::MalformedHeader));
    }

    #[test]
    fn a_tampered_block_fails_its_hash() {
        let block = b"payload".to_vec();
        let mut framed = Vec::new();
        framed.extend_from_slice(&0_u32.to_le_bytes());
        framed.extend_from_slice(&Sha256::digest(b"other"));
        framed.extend_from_slice(&u32::try_from(block.len()).expect("a length").to_le_bytes());
        framed.extend_from_slice(&block);
        assert_eq!(dehash_blocks(&framed), None);
    }

    #[test]
    fn history_entries_are_read_after_their_entry() {
        let xml = concat!(
            "<KeePassFile><Root><Group><Entry>",
            "<String><Key>Title</Key><Value>t</Value></String>",
            "<String><Key>Password</Key><Value>current</Value></String>",
            "<History><Entry>",
            "<String><Key>Title</Key><Value>t</Value></String>",
            "<String><Key>Password</Key><Value>old</Value></String>",
            "</Entry></History></Entry></Group></Root></KeePassFile>"
        );
        let entries = parse_entries(xml.as_bytes(), None);
        let passwords: Vec<&str> = entries.iter().map(|entry| entry.password.expose_secret()).collect();
        assert_eq!(passwords, ["current", "old"]);
    }
}
