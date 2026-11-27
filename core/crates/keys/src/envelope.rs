use secrecy::SecretString;
use zeroize::{Zeroize, Zeroizing};

use crate::KeysError;
use crate::crypto::{self, NONCE_LEN};
use crate::encoding::{AccountId, Frame, HistoryId, Label, Origin, Scope, Version};
use crate::json::{self, JsonValue, Members, push_string};
use crate::keys::ScopeKey;
use crate::padding;
use crate::record_id::check_record_id;
use crate::trust::check_format;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Platform {
    Macos,
    Ios,
    Linux,
    Windows,
}

impl Platform {
    fn name(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Ios => "ios",
            Self::Linux => "linux",
            Self::Windows => "windows",
        }
    }
}

// The parent kinds of ADR 0056's envelope table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ParentKind {
    Connection,
    LibraryConnection,
    SshProfile,
    CredentialProfile,
    Settings(Platform),
}

impl ParentKind {
    pub fn name(self) -> String {
        match self {
            Self::Connection => "connection".to_owned(),
            Self::LibraryConnection => "library_connection".to_owned(),
            Self::SshProfile => "ssh_profile".to_owned(),
            Self::CredentialProfile => "credential_profile".to_owned(),
            Self::Settings(platform) => format!("{}_settings", platform.name()),
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "connection" => Ok(Self::Connection),
            "library_connection" => Ok(Self::LibraryConnection),
            "ssh_profile" => Ok(Self::SshProfile),
            "credential_profile" => Ok(Self::CredentialProfile),
            "macos_settings" => Ok(Self::Settings(Platform::Macos)),
            "ios_settings" => Ok(Self::Settings(Platform::Ios)),
            "linux_settings" => Ok(Self::Settings(Platform::Linux)),
            "windows_settings" => Ok(Self::Settings(Platform::Windows)),
            _ => Err(KeysError::encoding("not a parent kind of the envelope table")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SecretKind {
    Password,
    SslKeyPassphrase,
    SshPassword,
    SshKeyPassphrase,
    SshTotpSecret,
    // One per secure field a driver plugin declares.
    Plugin(String),
    AiKey(String),
}

impl SecretKind {
    pub fn name(&self) -> String {
        match self {
            Self::Password => "password".to_owned(),
            Self::SslKeyPassphrase => "ssl_key_passphrase".to_owned(),
            Self::SshPassword => "ssh_password".to_owned(),
            Self::SshKeyPassphrase => "ssh_key_passphrase".to_owned(),
            Self::SshTotpSecret => "ssh_totp_secret".to_owned(),
            Self::Plugin(field) => format!("plugin.{field}"),
            Self::AiKey(provider) => format!("ai_key.{provider}"),
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        let named = |rest: &str| {
            if rest.is_empty() || rest.contains('/') {
                Err(KeysError::encoding("a secret kind's id is empty or holds `/`"))
            } else {
                Ok(rest.to_owned())
            }
        };
        match text {
            "password" => Ok(Self::Password),
            "ssl_key_passphrase" => Ok(Self::SslKeyPassphrase),
            "ssh_password" => Ok(Self::SshPassword),
            "ssh_key_passphrase" => Ok(Self::SshKeyPassphrase),
            "ssh_totp_secret" => Ok(Self::SshTotpSecret),
            _ => {
                if let Some(field) = text.strip_prefix("plugin.") {
                    named(field).map(Self::Plugin)
                } else if let Some(provider) = text.strip_prefix("ai_key.") {
                    named(provider).map(Self::AiKey)
                } else {
                    Err(KeysError::encoding("not a secret kind of the envelope table"))
                }
            }
        }
    }

    fn is_ssh(&self) -> bool {
        matches!(self, Self::SshPassword | Self::SshKeyPassphrase | Self::SshTotpSecret)
    }

    // A row of ADR 0056's envelope table.
    fn allowed_under(&self, parent: ParentKind, parent_id: &str) -> bool {
        match parent {
            ParentKind::Connection | ParentKind::LibraryConnection => {
                matches!(self, Self::Password | Self::SslKeyPassphrase | Self::Plugin(_)) || self.is_ssh()
            }
            ParentKind::SshProfile => self.is_ssh(),
            ParentKind::CredentialProfile => matches!(self, Self::Password),
            ParentKind::Settings(_) => matches!(self, Self::AiKey(_)) && parent_id == "ai",
        }
    }
}

// An envelope's record id: its parent's kind, the parent's record id and the secret kind (ADR 0052).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EnvelopeId {
    pub parent_kind: ParentKind,
    pub parent_id: String,
    pub secret_kind: SecretKind,
}

impl EnvelopeId {
    pub fn new(parent_kind: ParentKind, parent_id: &str, secret_kind: SecretKind) -> Result<Self, KeysError> {
        check_record_id(parent_id)?;
        if let SecretKind::Plugin(field) | SecretKind::AiKey(field) = &secret_kind {
            check_record_id(field)?;
        }
        check_record_id(&secret_kind.name())?;
        let id = Self {
            parent_kind,
            parent_id: parent_id.to_owned(),
            secret_kind,
        };
        check_record_id(&id.to_wire())?;
        // ADR 0052, Ids per kind: these parents are named by their UUID; a team library item keeps
        // the client id its library stores.
        if matches!(
            parent_kind,
            ParentKind::Connection | ParentKind::SshProfile | ParentKind::CredentialProfile
        ) {
            crate::encoding::uuid_from_wire(parent_id)?;
        }
        if SecretKind::parse(&id.secret_kind.name())? != id.secret_kind {
            return Err(KeysError::encoding("a secret kind's id is empty or holds `/`"));
        }
        if !id.secret_kind.allowed_under(parent_kind, parent_id) {
            return Err(KeysError::encoding(
                "no row of the envelope table has this parent and secret kind",
            ));
        }
        Ok(id)
    }

    // The parent's id is what lies between the first and the last `/`.
    pub fn parse(text: &str) -> Result<Self, KeysError> {
        check_record_id(text)?;
        let (parent_kind, rest) = text
            .split_once('/')
            .ok_or(KeysError::encoding("envelope id has no `/`"))?;
        let (parent_id, secret_kind) = rest
            .rsplit_once('/')
            .ok_or(KeysError::encoding("envelope id has one `/`"))?;
        let id = Self::new(
            ParentKind::parse(parent_kind)?,
            parent_id,
            SecretKind::parse(secret_kind)?,
        )?;
        if id.to_wire() != text {
            return Err(KeysError::encoding("envelope id is not in its form"));
        }
        Ok(id)
    }

    pub fn to_wire(&self) -> String {
        format!(
            "{}/{}/{}",
            self.parent_kind.name(),
            self.parent_id,
            self.secret_kind.name()
        )
    }
}

// The clear fields of a `secret_envelope` or `history_entry`, besides `suite`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sealed {
    pub kv: Version,
    pub nonce: [u8; NONCE_LEN],
    pub ct: Vec<u8>,
}

#[derive(Debug)]
pub struct EnvelopePlaintext {
    pub secret: SecretString,
    // The destination the secret was sealed for, compared at use with `check_destination`.
    pub dest: JsonValue,
}

pub(crate) fn envelope_subkey(
    key: &ScopeKey,
    origin: &Origin,
    scope: Scope,
    id: &EnvelopeId,
) -> Result<Zeroizing<[u8; 32]>, KeysError> {
    let mut info = Frame::new(Label::EnvelopeKey);
    info.origin(origin)
        .scope(scope)
        .lp(id.parent_kind.name().as_bytes())
        .lp(id.parent_id.as_bytes())
        .lp(id.secret_kind.name().as_bytes());
    crypto::hkdf32(key.expose(), &info.finish()?)
}

pub fn envelope_aad(origin: &Origin, scope: Scope, id: &EnvelopeId, kv: Version) -> Result<Vec<u8>, KeysError> {
    let mut aad = Frame::new(Label::Envelope);
    aad.origin(origin)
        .scope(scope)
        .lp(id.parent_kind.name().as_bytes())
        .lp(id.parent_id.as_bytes())
        .lp(id.secret_kind.name().as_bytes())
        .u32(kv.get());
    aad.finish()
}

pub fn envelope_plaintext(secret: &str, dest: &JsonValue) -> Result<Zeroizing<String>, KeysError> {
    if !dest.is_object() {
        return Err(KeysError::encoding("`dest` is not an object"));
    }
    const HEAD: &str = "{\"v\":1,\"secret\":";
    const MIDDLE: &str = ",\"dest\":";
    let len = HEAD.len() + json::string_len(secret) + MIDDLE.len() + dest.encoded_len() + 1;
    let mut out = Zeroizing::new(String::with_capacity(len));
    out.push_str(HEAD);
    push_string(&mut *out, secret);
    out.push_str(MIDDLE);
    dest.write(&mut *out);
    out.push('}');
    Ok(out)
}

// `key` is the scope key at version `kv`: a PK version in the personal scope, a TK version in a team.
pub fn seal_envelope(
    key: &ScopeKey,
    origin: &Origin,
    scope: Scope,
    id: &EnvelopeId,
    kv: Version,
    secret: &str,
    dest: &JsonValue,
) -> Result<Sealed, KeysError> {
    let plaintext = envelope_plaintext(secret, dest)?;
    seal_envelope_plaintext(
        key,
        origin,
        scope,
        id,
        kv,
        plaintext.as_bytes(),
        crypto::random_array()?,
    )
}

pub(crate) fn seal_envelope_plaintext(
    key: &ScopeKey,
    origin: &Origin,
    scope: Scope,
    id: &EnvelopeId,
    kv: Version,
    plaintext: &[u8],
    nonce: [u8; NONCE_LEN],
) -> Result<Sealed, KeysError> {
    let padded = padding::pad(plaintext)?;
    let subkey = envelope_subkey(key, origin, scope, id)?;
    let ct = crypto::aes_seal(&subkey, &nonce, &envelope_aad(origin, scope, id, kv)?, &padded)?;
    Ok(Sealed { kv, nonce, ct })
}

pub fn open_envelope(
    key: &ScopeKey,
    origin: &Origin,
    scope: Scope,
    id: &EnvelopeId,
    sealed: &Sealed,
) -> Result<EnvelopePlaintext, KeysError> {
    check_sealed_len(&sealed.ct)?;
    let subkey = envelope_subkey(key, origin, scope, id)?;
    let padded = crypto::aes_open(
        &subkey,
        &sealed.nonce,
        &envelope_aad(origin, scope, id, sealed.kv)?,
        &sealed.ct,
    )?;
    parse_envelope_plaintext(padding::unpad(&padded)?)
}

// `{"v": 1, "secret": <string>, "dest": <object>}`, after the padding is removed.
pub fn parse_envelope_plaintext(plaintext: &[u8]) -> Result<EnvelopePlaintext, KeysError> {
    let mut value = Zeroizing::new(json::parse(plaintext)?);
    let dest = {
        let mut members = Members::of(&value)?;
        check_format(&mut members)?;
        members.string("secret")?;
        members.object("dest")?.clone()
    };
    // The secret's text moves into the SecretString, which wipes it, rather than being copied.
    // At its exact length, so SecretString's conversion to a boxed str moves nothing.
    let mut text = Zeroizing::new(value.take_string("secret").unwrap_or_default());
    let mut exact = String::with_capacity(text.len());
    exact.push_str(&text);
    text.zeroize();
    let secret = SecretString::from(exact);
    Ok(EnvelopePlaintext { secret, dest })
}

// At use: the sealed destination against the one built from the record's current fields.
pub fn check_destination(sealed: &JsonValue, current: &JsonValue) -> Result<(), KeysError> {
    if sealed.same_as(current) {
        Ok(())
    } else {
        Err(KeysError::Destination)
    }
}

// A sealed body's ciphertext is a padded length on the scale plus the 16-byte tag.
pub fn check_sealed_len(ct: &[u8]) -> Result<(), KeysError> {
    let padded = ct
        .len()
        .checked_sub(crypto::TAG_LEN)
        .ok_or(KeysError::encoding("ct shorter than its tag"))?;
    if padding::on_scale(padded) {
        Ok(())
    } else {
        Err(KeysError::encoding("ct is not a padded length plus its tag"))
    }
}

pub(crate) fn history_subkey(
    key: &ScopeKey,
    origin: &Origin,
    account: AccountId,
    id: HistoryId,
) -> Result<Zeroizing<[u8; 32]>, KeysError> {
    let mut info = Frame::new(Label::HistoryKey);
    info.origin(origin)
        .scope(Scope::History(account))
        .lp(id.to_wire().as_bytes());
    crypto::hkdf32(key.expose(), &info.finish()?)
}

pub fn history_aad(origin: &Origin, account: AccountId, id: HistoryId, kv: Version) -> Result<Vec<u8>, KeysError> {
    let mut aad = Frame::new(Label::History);
    aad.origin(origin)
        .scope(Scope::History(account))
        .lp(id.to_wire().as_bytes())
        .u32(kv.get());
    aad.finish()
}

pub fn history_plaintext(entry: &JsonValue) -> Result<Zeroizing<String>, KeysError> {
    if !entry.is_object() {
        return Err(KeysError::encoding("`entry` is not an object"));
    }
    const HEAD: &str = "{\"v\":1,\"entry\":";
    let mut out = Zeroizing::new(String::with_capacity(HEAD.len() + entry.encoded_len() + 1));
    out.push_str(HEAD);
    entry.write(&mut *out);
    out.push('}');
    Ok(out)
}

// `key` is the HK version `kv`. A device that pushes an entry again seals it under the newest HK.
pub fn seal_history(
    key: &ScopeKey,
    origin: &Origin,
    account: AccountId,
    id: HistoryId,
    kv: Version,
    entry: &JsonValue,
) -> Result<Sealed, KeysError> {
    let plaintext = history_plaintext(entry)?;
    seal_history_plaintext(
        key,
        origin,
        account,
        id,
        kv,
        plaintext.as_bytes(),
        crypto::random_array()?,
    )
}

pub(crate) fn seal_history_plaintext(
    key: &ScopeKey,
    origin: &Origin,
    account: AccountId,
    id: HistoryId,
    kv: Version,
    plaintext: &[u8],
    nonce: [u8; NONCE_LEN],
) -> Result<Sealed, KeysError> {
    let padded = padding::pad(plaintext)?;
    let subkey = history_subkey(key, origin, account, id)?;
    let ct = crypto::aes_seal(&subkey, &nonce, &history_aad(origin, account, id, kv)?, &padded)?;
    Ok(Sealed { kv, nonce, ct })
}

pub fn open_history(
    key: &ScopeKey,
    origin: &Origin,
    account: AccountId,
    id: HistoryId,
    sealed: &Sealed,
) -> Result<HistoryPlaintext, KeysError> {
    check_sealed_len(&sealed.ct)?;
    let subkey = history_subkey(key, origin, account, id)?;
    let padded = crypto::aes_open(
        &subkey,
        &sealed.nonce,
        &history_aad(origin, account, id, sealed.kv)?,
        &sealed.ct,
    )?;
    parse_history_plaintext(padding::unpad(&padded)?)
}

// `{"v": 1, "entry": <object>}`, after the padding is removed.
pub fn parse_history_plaintext(plaintext: &[u8]) -> Result<HistoryPlaintext, KeysError> {
    let mut value = Zeroizing::new(json::parse(plaintext)?);
    {
        let mut members = Members::of(&value)?;
        check_format(&mut members)?;
        members.object("entry")?;
    }
    Ok(HistoryPlaintext(Zeroizing::new(
        value.take_member("entry").unwrap_or(JsonValue::Null),
    )))
}

// A history entry's fields, wiped on drop; Debug never prints them.
pub struct HistoryPlaintext(Zeroizing<JsonValue>);

impl HistoryPlaintext {
    pub fn expose(&self) -> &JsonValue {
        &self.0
    }
}

impl std::fmt::Debug for HistoryPlaintext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HistoryPlaintext(redacted)")
    }
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;
    use uuid::Uuid;

    use super::{
        EnvelopeId, ParentKind, Platform, SecretKind, check_destination, open_envelope, open_history, seal_envelope,
        seal_history,
    };
    use crate::KeysError;
    use crate::encoding::{AccountId, HistoryId, Origin, Scope, Version};
    use crate::json::parse;
    use crate::keys::ScopeKey;

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    #[test]
    fn ids_follow_the_envelope_table() {
        let id = EnvelopeId::parse("connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/ssh_key_passphrase").unwrap();
        assert_eq!(id.secret_kind, SecretKind::SshKeyPassphrase);
        assert!(EnvelopeId::parse("macos_settings/ai/ai_key.openai").is_ok());
        assert!(EnvelopeId::parse("library_connection/6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44/plugin.token").is_ok());
        assert_eq!(
            EnvelopeId::parse("ssh_profile/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/password").unwrap_err(),
            KeysError::Encoding {
                what: "no row of the envelope table has this parent and secret kind"
            }
        );
        assert!(EnvelopeId::parse("credential_profile/X/ssh_password").is_err());
        assert!(EnvelopeId::parse("linux_settings/theme/ai_key.openai").is_err());
        assert!(EnvelopeId::parse("connection/X/plugin.").is_err());
        assert!(EnvelopeId::parse("tag/X/password").is_err());
        assert!(
            EnvelopeId::parse("connection/X/password").is_err(),
            "a connection is named by its UUID"
        );
        assert!(EnvelopeId::parse("connection/6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44/password").is_err());
        assert!(
            EnvelopeId::new(
                ParentKind::Connection,
                "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
                SecretKind::Plugin("a/b".into())
            )
            .is_err()
        );
        assert!(EnvelopeId::parse("connection//password").is_err());
        assert!(
            EnvelopeId::new(
                ParentKind::LibraryConnection,
                "x",
                SecretKind::Plugin("x".repeat(1 << 20))
            )
            .is_err()
        );
        let long = format!("library_connection/{}/password", "x".repeat(1 << 20));
        assert_eq!(
            EnvelopeId::parse(&long).unwrap_err(),
            KeysError::Encoding {
                what: "record id is empty, too long or holds U+0000"
            }
        );
        assert_eq!(
            EnvelopeId::new(ParentKind::Settings(Platform::Ios), "ai", SecretKind::AiKey("x".into()))
                .unwrap()
                .to_wire(),
            "ios_settings/ai/ai_key.x"
        );
    }

    #[test]
    fn an_envelope_binds_its_ids_version_and_destination() {
        let key = ScopeKey::generate().unwrap();
        let scope = Scope::Personal(AccountId(Uuid::from_u128(1)));
        let id = EnvelopeId::parse("connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/password").unwrap();
        let dest = parse(br#"{"engine":"postgres","host":"db.internal","port":5432}"#).unwrap();
        let sealed = seal_envelope(&key, &origin(), scope, &id, Version::new(3).unwrap(), "hunter2", &dest).unwrap();
        assert_eq!(sealed.ct.len(), 128 + 16);
        let opened = open_envelope(&key, &origin(), scope, &id, &sealed).unwrap();
        assert_eq!(opened.secret.expose_secret(), "hunter2");
        assert_eq!(check_destination(&opened.dest, &dest), Ok(()));
        let moved = parse(br#"{"engine":"postgres","host":"evil.example","port":5432}"#).unwrap();
        assert_eq!(check_destination(&opened.dest, &moved), Err(KeysError::Destination));

        let other = EnvelopeId::parse("connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/ssl_key_passphrase").unwrap();
        assert_eq!(
            open_envelope(&key, &origin(), scope, &other, &sealed).unwrap_err(),
            KeysError::Open
        );
        let mut downgraded = sealed.clone();
        downgraded.kv = Version::new(2).unwrap();
        assert_eq!(
            open_envelope(&key, &origin(), scope, &id, &downgraded).unwrap_err(),
            KeysError::Open
        );
        let team = Scope::Team(crate::encoding::TeamId(Uuid::from_u128(1)));
        assert_eq!(
            open_envelope(&key, &origin(), team, &id, &sealed).unwrap_err(),
            KeysError::Open
        );
    }

    #[test]
    fn history_entries_round_trip() {
        let key = ScopeKey::generate().unwrap();
        let account = AccountId(Uuid::from_u128(1));
        let id = HistoryId(Uuid::from_u128(2));
        let entry = parse(br#"{"query":"select 1","executed_at":"2026-11-25T10:00:00Z"}"#).unwrap();
        let sealed = seal_history(&key, &origin(), account, id, Version::FIRST, &entry).unwrap();
        assert!(
            open_history(&key, &origin(), account, id, &sealed)
                .unwrap()
                .expose()
                .same_as(&entry)
        );
        assert_eq!(
            open_history(&key, &origin(), account, HistoryId(Uuid::from_u128(3)), &sealed).unwrap_err(),
            KeysError::Open
        );
    }
}
