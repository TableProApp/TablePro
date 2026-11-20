// The secrets DBX keeps in `connection_secrets`, read as `Storage::load_connections` and
// `load_tunnel_profiles_readonly` read them (crates/dbx-core/src/persistence/storage.rs). A value is a `dbxenc1`
// envelope in `secret_enc`, or plain text in `secret` from before DBX encrypted them; a password left inline in a
// connection's JSON is one DBX never reads, while a tunnel profile's still counts.

use std::collections::HashMap;
use std::path::PathBuf;

use aws_lc_rs::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use secrecy::zeroize::Zeroizing;
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;

use super::config::{Hop, HopSecrets, LEGACY_LAYER};
use super::key::{self, Key, Store};
use crate::ForeignCredentials;
use crate::apps::sqlite::Database;

const ENVELOPE: &str = "dbxenc1";
// `TUNNEL_SECRET_NAMESPACE_PREFIX` and `CONFIG_SECRET_BLOB_KEY`: a profile's secrets are one JSON blob.
const PROFILE_NAMESPACE: &str = "tunnel_profile.";
const PROFILE_BLOB: &str = "config";

struct Row {
    plain: Option<SecretString>,
    envelope: Option<String>,
}

// A tunnel profile's SSH secrets, from its own JSON or from its blob.
#[derive(Deserialize)]
struct ProfileSecrets {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    password: Option<SecretString>,
    #[serde(default)]
    key_passphrase: Option<SecretString>,
}

// The rows a password can come from, read in the same read transaction as the connections they belong to.
pub(super) struct SecretRows {
    rows: HashMap<(String, String), Row>,
    profiles: HashMap<String, ProfileSecrets>,
    // A query stopped before its end, such as on a lock DBX held.
    torn: bool,
}

impl SecretRows {
    pub(super) fn read(db: &Database) -> Self {
        let mut held = Self {
            rows: HashMap::new(),
            profiles: HashMap::new(),
            torn: false,
        };
        held.read_rows(db);
        held.read_profiles(db);
        held
    }

    fn read_rows(&mut self, db: &Database) {
        let columns = db.columns("connection_secrets");
        if columns.is_empty() {
            return;
        }
        let envelope = if columns.contains("secret_enc") {
            "secret_enc"
        } else {
            "NULL"
        };
        let sql = format!(
            "SELECT connection_id, key, secret, {envelope} FROM connection_secrets \
             WHERE key IN ('password', 'ssh_password', 'ssh_key_passphrase', '{PROFILE_BLOB}') \
             OR key LIKE 'transport_layers.%' OR key LIKE 'ssh_tunnels.%'"
        );
        let Some(mut statement) = db.prepare(&sql) else {
            self.torn = true;
            return;
        };
        while let Some(row) = statement.next_row() {
            if let (Some(namespace), Some(name)) = (row.text(0), row.text(1)) {
                let held = Row {
                    plain: row.text(2).map(SecretString::from),
                    envelope: row.text(3),
                };
                self.rows.insert((namespace, name), held);
            }
        }
        self.torn |= !statement.finished();
    }

    fn read_profiles(&mut self, db: &Database) {
        if db.columns("tunnel_profiles").is_empty() {
            return;
        }
        let Some(mut statement) = db.prepare("SELECT id, config_json FROM tunnel_profiles") else {
            self.torn = true;
            return;
        };
        while let Some(row) = statement.next_row() {
            let (Some(id), Some(json)) = (row.text(0), row.text(1).map(Zeroizing::new)) else {
                continue;
            };
            // DBX leaves out a profile that does not parse, and so does the route.
            if let Ok(secrets) = serde_json::from_str::<ProfileSecrets>(&json) {
                self.profiles.insert(id, secrets);
            }
        }
        self.torn |= !statement.finished();
    }
}

enum Stored {
    Value(SecretString),
    Absent,
    // There, but nothing here opens it.
    Shut,
}

pub(super) struct Secrets {
    held: SecretRows,
    config_dir: PathBuf,
    store: Store,
    // Looked up at the first envelope, so an import with none never asks the store.
    key: Option<Option<Key>>,
    missed: bool,
}

impl Secrets {
    pub(super) fn new(held: SecretRows, config_dir: PathBuf, store: Store) -> Self {
        if held.torn {
            tracing::warn!("DBX's secrets did not read to their end");
        }
        Self {
            missed: held.torn,
            held,
            config_dir,
            store,
            key: None,
        }
    }

    // Whether a secret DBX holds may have stayed shut.
    pub(super) fn missed(&self) -> bool {
        self.missed
    }

    // The database password, and the password and key passphrase of the hop next to the database.
    pub(super) fn credentials(&mut self, connection_id: &str, target: Option<&Hop>) -> ForeignCredentials {
        let password = self.first(connection_id, &["password".to_owned()]);
        let (ssh_password, key_passphrase) = match target.map(|hop| &hop.secrets) {
            Some(HopSecrets::Layer { index, id }) => {
                let (password, passphrase) = layer_secret_names(*index, id);
                (
                    self.first(connection_id, &password),
                    self.first(connection_id, &passphrase),
                )
            }
            Some(HopSecrets::Profile(profile)) => self.profile(profile),
            None => (None, None),
        };
        ForeignCredentials {
            password,
            ssh_password,
            key_passphrase,
        }
    }

    // DBX reads the first name that holds a value and fails on one it cannot open, so a shut one ends the search.
    fn first(&mut self, namespace: &str, names: &[String]) -> Option<SecretString> {
        for name in names {
            match self.read(namespace, name) {
                Stored::Value(value) => return Some(value),
                Stored::Absent => {}
                Stored::Shut => return None,
            }
        }
        None
    }

    // The profile's own fields, each filled from its blob only where it is empty, as DBX merges them.
    fn profile(&mut self, profile: &str) -> (Option<SecretString>, Option<SecretString>) {
        let (own_password, own_passphrase) = match self.held.profiles.get(profile) {
            Some(own) => (
                own.password.clone().filter(written),
                own.key_passphrase.clone().filter(written),
            ),
            None => (None, None),
        };
        let namespace = format!("{PROFILE_NAMESPACE}{profile}");
        let (blob_password, blob_passphrase) = match self.read(&namespace, PROFILE_BLOB) {
            Stored::Value(blob) => match serde_json::from_str::<ProfileSecrets>(blob.expose_secret()) {
                Ok(blob) if blob.kind == "ssh" => (blob.password, blob.key_passphrase),
                Ok(_) => (None, None),
                Err(error) => {
                    // Not the message, which can quote the password it met.
                    tracing::warn!(
                        line = error.line(),
                        column = error.column(),
                        "a DBX tunnel profile's secrets do not parse"
                    );
                    self.missed = true;
                    (None, None)
                }
            },
            Stored::Absent | Stored::Shut => (None, None),
        };
        (
            own_password.or(blob_password.filter(written)),
            own_passphrase.or(blob_passphrase.filter(written)),
        )
    }

    fn read(&mut self, namespace: &str, name: &str) -> Stored {
        let Some((plain, envelope)) = self
            .held
            .rows
            .get(&(namespace.to_owned(), name.to_owned()))
            .map(|row| (row.plain.clone(), row.envelope.clone()))
        else {
            return Stored::Absent;
        };
        if let Some(envelope) = envelope.filter(|envelope| !envelope.is_empty()) {
            let opened = self.key().and_then(|key| open(key, namespace, name, &envelope));
            return match opened {
                Some(value) => Stored::Value(value),
                None => {
                    self.missed = true;
                    Stored::Shut
                }
            };
        }
        match plain.filter(written) {
            Some(plain) => Stored::Value(plain),
            None => Stored::Absent,
        }
    }

    fn key(&mut self) -> Option<&Key> {
        self.key
            .get_or_insert_with(|| key::find(&self.config_dir, &self.store))
            .as_ref()
    }
}

fn written(secret: &SecretString) -> bool {
    !secret.expose_secret().is_empty()
}

// `transport_layer_ssh_password_key` and its fallbacks: the single host a connection kept before layers, else the
// chain of `ssh_tunnels` it kept after. A blank id falls back to the layer's place.
fn layer_secret_names(index: usize, id: &str) -> ([String; 2], [String; 2]) {
    let trimmed = id.trim();
    let (layer, hop) = if trimmed.is_empty() {
        (index.to_string(), index.to_string())
    } else {
        (trimmed.to_owned(), id.to_owned())
    };
    let older = |single: &str, chained: &str| {
        if id == LEGACY_LAYER {
            single.to_owned()
        } else {
            format!("ssh_tunnels.{hop}.{chained}")
        }
    };
    (
        [
            format!("transport_layers.{layer}.ssh_password"),
            older("ssh_password", "password"),
        ],
        [
            format!("transport_layers.{layer}.ssh_key_passphrase"),
            older("ssh_key_passphrase", "key_passphrase"),
        ],
    )
}

// `SecretCodec::decrypt`: `dbxenc1.<nonce>.<ciphertext and tag>`, AES-256-GCM over data that names the row, so an
// envelope moved to another row does not open.
fn open(key: &Key, namespace: &str, name: &str, envelope: &str) -> Option<SecretString> {
    let mut parts = envelope.split('.');
    if parts.next() != Some(ENVELOPE) {
        return None;
    }
    let nonce = URL_SAFE_NO_PAD.decode(parts.next()?).ok()?;
    let mut sealed = Zeroizing::new(URL_SAFE_NO_PAD.decode(parts.next()?).ok()?);
    if parts.next().is_some() {
        return None;
    }
    let nonce = Nonce::try_assume_unique_for_key(&nonce).ok()?;
    let cipher = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key.as_slice()).ok()?);
    let bound = format!("dbx-secret-v1\0{namespace}\0{name}");
    let plain = cipher
        .open_in_place(nonce, Aad::from(bound.as_bytes()), sealed.as_mut_slice())
        .ok()?;
    std::str::from_utf8(plain).ok().map(SecretString::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_key() -> Key {
        Zeroizing::new(std::array::from_fn(|index| u8::try_from(index).expect("a byte")))
    }

    // Written by DBX's `SecretCodec::encrypt` under bytes 0 to 31, for row (`c-pg`, `password`).
    const ENVELOPE_OF_C_PG: &str = "dbxenc1.hfbQTNxH8kGvTnAm.MVw59t-CPGvoxzDfrguWZ7LJ_mc8nW2VxDiHEflCu0Q";

    #[test]
    fn an_envelope_opens_only_with_its_key_and_on_its_own_row() {
        let key = fixture_key();

        assert_eq!(
            open(&key, "c-pg", "password", ENVELOPE_OF_C_PG)
                .as_ref()
                .map(ExposeSecret::expose_secret),
            Some("orders-db-secret")
        );
        assert!(open(&key, "c-maria", "password", ENVELOPE_OF_C_PG).is_none());
        assert!(open(&key, "c-pg", "ssh_password", ENVELOPE_OF_C_PG).is_none());
        assert!(open(&Zeroizing::new([7; 32]), "c-pg", "password", ENVELOPE_OF_C_PG).is_none());
        assert!(open(&key, "c-pg", "password", &format!("{ENVELOPE_OF_C_PG}.x")).is_none());
        assert!(
            open(
                &key,
                "c-pg",
                "password",
                &ENVELOPE_OF_C_PG.replacen("dbxenc1", "dbxenc2", 1)
            )
            .is_none()
        );
        assert!(
            open(&key, "c-pg", "password", "dbxenc1.AAAA.AAAA").is_none(),
            "a nonce of 3 bytes"
        );
    }

    #[test]
    fn a_hop_s_secrets_are_looked_for_where_each_dbx_kept_them() {
        assert_eq!(
            layer_secret_names(0, "l1"),
            (
                [
                    "transport_layers.l1.ssh_password".to_owned(),
                    "ssh_tunnels.l1.password".to_owned()
                ],
                [
                    "transport_layers.l1.ssh_key_passphrase".to_owned(),
                    "ssh_tunnels.l1.key_passphrase".to_owned()
                ]
            )
        );
        assert_eq!(
            layer_secret_names(0, LEGACY_LAYER).0,
            [
                "transport_layers.legacy.ssh_password".to_owned(),
                "ssh_password".to_owned()
            ]
        );
        assert_eq!(
            layer_secret_names(3, " ").1,
            [
                "transport_layers.3.ssh_key_passphrase".to_owned(),
                "ssh_tunnels.3.key_passphrase".to_owned()
            ]
        );
        assert_eq!(
            layer_secret_names(1, " h2 ").0,
            [
                "transport_layers.h2.ssh_password".to_owned(),
                "ssh_tunnels. h2 .password".to_owned()
            ],
            "DBX trims a layer's id and keeps an older hop's as written"
        );
    }
}
