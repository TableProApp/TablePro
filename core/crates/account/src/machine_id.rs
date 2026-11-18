use std::fmt::Write as _;

use aws_lc_rs::hmac;

// Changing it makes every machine a new device. Both build profiles share it.
const KEY: &str = "app.tablepro.TablePro";

// An HMAC of the platform's machine ID, which machine-id(5) says never to send as it is. The machine ID itself
// never leaves the machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineId(String);

impl MachineId {
    // Linux's /etc/machine-id, per machine-id(5): 32 hex characters and a newline, never all zero.
    pub fn derive(machine_id: &str) -> Option<Self> {
        decode_machine_id(machine_id.trim_end_matches('\n')).map(|raw| Self::keyed(&raw))
    }

    // Windows's HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid, 8-4-4-4-12 hex digits: the same HMAC over the
    // 16 bytes they write, in the order they are written.
    pub fn derive_machine_guid(machine_guid: &str) -> Option<Self> {
        let groups: Vec<&str> = machine_guid.split('-').collect();
        let lengths: Vec<usize> = groups.iter().map(|group| group.len()).collect();
        if lengths != [8, 4, 4, 4, 12] {
            return None;
        }
        decode_machine_id(&groups.concat()).map(|raw| Self::keyed(&raw))
    }

    fn keyed(raw: &[u8; 16]) -> Self {
        let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, KEY.as_bytes()), raw);
        Self(hex(tag.as_ref()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn decode_machine_id(text: &str) -> Option<[u8; 16]> {
    // from_str_radix would also take a pair such as "+f".
    if text.len() != 32 || !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let mut raw = [0u8; 16];
    let (pairs, _) = text.as_bytes().as_chunks::<2>();
    for (byte, pair) in raw.iter_mut().zip(pairs) {
        let pair = std::str::from_utf8(pair).ok()?;
        *byte = u8::from_str_radix(pair, 16).ok()?;
    }
    (raw != [0u8; 16]).then_some(raw)
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut text, byte| {
            let _ = write!(text, "{byte:02x}");
            text
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ETC_MACHINE_ID: &str = "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n";
    // python3 -c 'import hmac,hashlib;print(hmac.new(b"app.tablepro.TablePro",
    //   bytes.fromhex("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20"),hashlib.sha256).hexdigest())'
    const EXPECTED: &str = "95af81c0a8cfbaf248d6e4f595ba544effb155bbf8d0aae9ca4e86c69cfc170e";

    #[test]
    fn the_id_is_the_hmac_of_the_raw_machine_id_keyed_with_the_application_id() {
        let id = MachineId::derive(ETC_MACHINE_ID).expect("a machine ID");

        assert_eq!(id.as_str(), EXPECTED);
    }

    #[test]
    fn the_id_is_64_lowercase_hex_characters_and_never_the_machine_id() {
        let id = MachineId::derive(ETC_MACHINE_ID).expect("a machine ID");

        assert_eq!(id.as_str().len(), 64);
        assert!(
            id.as_str()
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        );
        assert!(!id.as_str().contains(ETC_MACHINE_ID.trim_end()));
    }

    #[test]
    fn upper_case_hex_names_the_same_machine() {
        let lower = MachineId::derive(ETC_MACHINE_ID);
        let upper = MachineId::derive(&ETC_MACHINE_ID.to_uppercase());

        assert_eq!(lower, upper);
    }

    #[test]
    fn another_machine_gets_another_id() {
        let first = MachineId::derive(ETC_MACHINE_ID);
        let second = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f21\n");

        assert_ne!(first, second);
    }

    #[test]
    fn what_is_not_a_machine_id_is_refused() {
        for text in [
            "",
            "\n",
            "uninitialized\n",
            "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f2\n",
            "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f200\n",
            "4c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20\n",
            "zc4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n",
            "+c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n",
            " 4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n",
            "00000000000000000000000000000000\n",
        ] {
            assert_eq!(MachineId::derive(text), None, "{text:?}");
        }
    }

    #[test]
    fn a_machine_guid_is_keyed_as_linux_keys_its_machine_id() {
        let windows = MachineId::derive_machine_guid("4c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20").expect("a machine ID");

        assert_eq!(windows.as_str(), EXPECTED);
        assert_eq!(Some(windows), MachineId::derive(ETC_MACHINE_ID));
    }

    #[test]
    fn a_machine_guid_gives_its_own_id_in_either_case() {
        // python3 -c 'import hmac,hashlib;print(hmac.new(b"app.tablepro.TablePro",
        //   bytes.fromhex("d3b07384d1134ec6a2f16a3f0c2e9b7a"),hashlib.sha256).hexdigest())'
        let expected = "304a889059f4befc83a542069ca52d990fd963e22766f6db230543bfddf7e336";

        let lower = MachineId::derive_machine_guid("d3b07384-d113-4ec6-a2f1-6a3f0c2e9b7a").expect("a machine ID");
        let upper = MachineId::derive_machine_guid("D3B07384-D113-4EC6-A2F1-6A3F0C2E9B7A").expect("a machine ID");

        assert_eq!(lower.as_str(), expected);
        assert_eq!(lower, upper);
    }

    #[test]
    fn what_is_not_a_machine_guid_is_refused() {
        for text in [
            "",
            "4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20",
            "{4c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20}",
            " 4c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20",
            "4c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f2",
            "4c4f5e2a-0b6d4-f3c-9e8a-7b6c5d4e3f20",
            "zc4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20",
            "+c4f5e2a-0b6d-4f3c-9e8a-7b6c5d4e3f20",
            "00000000-0000-0000-0000-000000000000",
        ] {
            assert_eq!(MachineId::derive_machine_guid(text), None, "{text:?}");
        }
    }
}
