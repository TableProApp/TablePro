// Writes KDBX 3.1 files and main key files laid out as the IDE writes them, for tests.

use std::io::Write;

use aes::cipher::block_padding::Pkcs7;
use aes::cipher::{BlockEncryptMut, KeyIvInit};
use aes::{Aes128, Aes256};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use flate2::Compression;
use flate2::write::GzEncoder;
use sha2::{Digest, Sha256};

use super::inner_stream::InnerStreamCipher;
use super::kdbx::aes_kdf;

pub(crate) const BUILT_IN_KEY: &[u8; 16] = b"Proxy Config Sec";

pub(crate) struct TestEntry<'a> {
    title: &'a str,
    user_name: &'a str,
    password: &'a str,
}

impl<'a> TestEntry<'a> {
    pub(crate) fn new(title: &'a str, user_name: &'a str, password: &'a str) -> Self {
        Self {
            title,
            user_name,
            password,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum InnerStream {
    Salsa20,
    ChaCha20,
    // An id no reader knows, so values are written as they are, base64 only.
    Unknown,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct KdbxOptions {
    pub rounds: u64,
    pub compressed: bool,
    pub inner_stream: InnerStream,
}

impl Default for KdbxOptions {
    fn default() -> Self {
        Self {
            rounds: 60,
            compressed: false,
            inner_stream: InnerStream::ChaCha20,
        }
    }
}

// Fixed bytes per label, so a written file is the same on every run.
pub(crate) fn bytes(label: &str, count: usize) -> Vec<u8> {
    let mut output = Vec::with_capacity(count);
    let mut counter = 0_u32;
    while output.len() < count {
        let mut hasher = Sha256::new();
        hasher.update(label.as_bytes());
        hasher.update(counter.to_le_bytes());
        output.extend_from_slice(&hasher.finalize());
        counter += 1;
    }
    output.truncate(count);
    output
}

pub(crate) fn make_kdbx(main_key: &[u8], entries: &[TestEntry<'_>], options: KdbxOptions) -> Vec<u8> {
    let main_seed = bytes("main seed", 32);
    let transform_seed = bytes("transform seed", 32);
    let encryption_iv = bytes("encryption iv", 16);
    let protected_stream_key = bytes("protected stream key", 32);
    let stream_start_bytes = bytes("stream start", 32);
    let stream_id = match options.inner_stream {
        InnerStream::Salsa20 => 2_u32,
        InnerStream::ChaCha20 => 3,
        InnerStream::Unknown => 9,
    };

    let mut cipher = InnerStreamCipher::for_stream(stream_id, &protected_stream_key);
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<KeePassFile><Root><Group><Name>IntelliJ Platform</Name>\n",
    );
    for entry in entries {
        let protected = STANDARD.encode(match &mut cipher {
            Some(cipher) => cipher.process(entry.password.as_bytes()).expect("ciphertext"),
            None => entry.password.as_bytes().to_vec(),
        });
        xml.push_str(&format!(
            "<Entry>\n<String><Key>Title</Key><Value>{}</Value></String>\n<String><Key>UserName</Key><Value>{}</Value></String>\n<String><Key>Password</Key><Value Protected=\"True\">{protected}</Value></String>\n</Entry>\n",
            entry.title, entry.user_name
        ));
    }
    xml.push_str("</Group></Root></KeePassFile>\n");
    let payload = if options.compressed {
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(xml.as_bytes()).expect("gzip");
        encoder.finish().expect("gzip")
    } else {
        xml.into_bytes()
    };

    let mut plaintext = stream_start_bytes.clone();
    plaintext.extend_from_slice(&0_u32.to_le_bytes());
    plaintext.extend_from_slice(&Sha256::digest(&payload));
    plaintext.extend_from_slice(&u32::try_from(payload.len()).expect("a length").to_le_bytes());
    plaintext.extend_from_slice(&payload);
    plaintext.extend_from_slice(&1_u32.to_le_bytes());
    plaintext.extend_from_slice(&[0; 32]);
    plaintext.extend_from_slice(&0_u32.to_le_bytes());

    let composite = Sha256::digest(Sha256::digest(main_key));
    let transformed = aes_kdf(&composite, &transform_seed, options.rounds).expect("a key");
    let mut hasher = Sha256::new();
    hasher.update(&main_seed);
    hasher.update(Sha256::digest(transformed));
    let final_key = hasher.finalize();
    let ciphertext = cbc::Encryptor::<Aes256>::new_from_slices(&final_key, &encryption_iv)
        .expect("a cipher")
        .encrypt_padded_vec_mut::<Pkcs7>(&plaintext);

    let mut file = Vec::new();
    file.extend_from_slice(&0x9AA2_D903_u32.to_le_bytes());
    file.extend_from_slice(&0xB54B_FB67_u32.to_le_bytes());
    file.extend_from_slice(&0x0003_0001_u32.to_le_bytes());
    let compression = u32::from(options.compressed);
    for (field, data) in [
        (3_u8, compression.to_le_bytes().to_vec()),
        (4, main_seed),
        (5, transform_seed),
        (6, options.rounds.to_le_bytes().to_vec()),
        (7, encryption_iv),
        (8, protected_stream_key),
        (9, stream_start_bytes),
        (10, stream_id.to_le_bytes().to_vec()),
        (0, vec![0x0d, 0x0a, 0x0d, 0x0a]),
    ] {
        file.push(field);
        file.extend_from_slice(&u16::try_from(data.len()).expect("a length").to_le_bytes());
        file.extend_from_slice(&data);
    }
    file.extend_from_slice(&ciphertext);
    file
}

// The main key under BUILT_IN: a big-endian IV length, the IV, then AES-128-CBC.
pub(crate) fn built_in_blob(main_key: &[u8]) -> Vec<u8> {
    let iv = bytes("main key iv", 16);
    let ciphertext = cbc::Encryptor::<Aes128>::new_from_slices(BUILT_IN_KEY, &iv)
        .expect("a cipher")
        .encrypt_padded_vec_mut::<Pkcs7>(main_key);
    let mut blob = 16_u32.to_be_bytes().to_vec();
    blob.extend_from_slice(&iv);
    blob.extend_from_slice(&ciphertext);
    blob
}

pub(crate) fn main_key_file(main_key: &[u8]) -> String {
    format!(
        "encryption: BUILT_IN\nisAutoGenerated: true\nvalue: !!binary {}\n",
        STANDARD.encode(built_in_blob(main_key))
    )
}
