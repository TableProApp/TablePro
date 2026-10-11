use std::{
    borrow::Cow,
    collections::{hash_map::Entry, HashMap},
    fmt::{self, Display, Formatter},
    ops::{BitXor, Range},
    str,
};

use hmac::{
    digest::{Digest, FixedOutput, KeyInit},
    Hmac,
    Mac,
};
use md5::Md5;
use sha1::Sha1;
use sha2::Sha256;
use std::sync::LazyLock;
use tokio::sync::RwLock;

use crate::{
    base64,
    bson::{Bson, Document},
    bson_compat::cstr,
    client::{
        auth::{
            self,
            sasl::{SaslContinue, SaslResponse, SaslStart},
            AuthMechanism,
            Credential,
        },
        options::ServerApi,
    },
    cmap::{Command, Connection},
    error::{Error, Result},
};

// The single letter attribute keys in SCRAM messages.
const ITERATION_COUNT_KEY: char = 'i';
const ERROR_KEY: char = 'e';
const PROOF_KEY: char = 'p';
const VERIFIER_KEY: char = 'v';
const NONCE_KEY: char = 'r';
const SALT_KEY: char = 's';
const CHANNEL_BINDING_KEY: char = 'c';
const USERNAME_KEY: char = 'n';

/// Constant specifying that we won't be using channel binding.
const NO_CHANNEL_BINDING: char = 'n';

/// The minimum number of iterations of the hash function that we will accept from the server.
const MIN_ITERATION_COUNT: u32 = 4096;
const MAX_ITERATION_COUNT: u32 = 100_000;

/// Cache of pre-computed salted passwords.
static CREDENTIAL_CACHE: LazyLock<RwLock<HashMap<CacheEntry, Vec<u8>>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

#[derive(Hash, Eq, PartialEq)]
struct CacheEntry {
    password: String,
    salt: Vec<u8>,
    i: u32,
    mechanism: ScramVersion,
}

/// The versions of SCRAM supported by the driver (classified according to hash function used).
#[derive(Debug, Hash, Eq, PartialEq, Clone)]
pub(crate) enum ScramVersion {
    Sha1,
    Sha256,
}

/// Contains the authentication info derived from a Credential.
pub(crate) struct ClientAuthInfo<'a> {
    pub(crate) username: &'a str,
    pub(crate) password: &'a str,
    pub(crate) source: &'a str,
}

/// The contents of the first round of a SCRAM handshake.
#[derive(Debug)]
pub(crate) struct FirstRound {
    pub(crate) client_first: ClientFirst,
    pub(crate) server_first: Document,
}

impl ScramVersion {
    /// Derives the authentication info from a credential.
    pub(crate) fn client_auth_info<'a>(
        &self,
        credential: &'a Credential,
    ) -> Result<ClientAuthInfo<'a>> {
        let username = credential
            .username
            .as_ref()
            .ok_or_else(|| Error::authentication_error("SCRAM", "no username supplied"))?;

        let password = credential
            .password
            .as_ref()
            .ok_or_else(|| Error::authentication_error("SCRAM", "no password supplied"))?;

        let source = match credential.source.as_ref() {
            Some(s) => s.as_str(),
            None => "admin",
        };

        if credential.mechanism_properties.is_some() {
            return Err(Error::authentication_error(
                "SCRAM",
                "mechanism properties MUST NOT be specified",
            ));
        };

        Ok(ClientAuthInfo {
            username,
            password,
            source,
        })
    }

    pub(super) fn build_speculative_client_first(
        &self,
        credential: &Credential,
    ) -> Result<ClientFirst> {
        self.build_client_first(credential, true, None)
    }

    /// Constructs the first client message in the SCRAM handshake.
    fn build_client_first(
        &self,
        credential: &Credential,
        include_db: bool,
        server_api: Option<&ServerApi>,
    ) -> Result<ClientFirst> {
        let info = self.client_auth_info(credential)?;

        Ok(ClientFirst::new(
            info.source,
            info.username,
            include_db,
            server_api.cloned(),
        ))
    }

    /// Sends the first client message in the SCRAM handshake.
    async fn send_client_first(
        &self,
        conn: &mut Connection,
        credential: &Credential,
        server_api: Option<&ServerApi>,
    ) -> Result<FirstRound> {
        let client_first = self.build_client_first(credential, false, server_api)?;

        let command = client_first.to_command(self)?;

        let server_first = conn.send_message(command).await?;

        Ok(FirstRound {
            client_first,
            server_first: server_first.auth_response_body("SCRAM")?,
        })
    }

    /// Perform SCRAM authentication for a given stream.
    pub(crate) async fn authenticate_stream(
        &self,
        conn: &mut Connection,
        credential: &Credential,
        server_api: Option<&ServerApi>,
        first_round: impl Into<Option<FirstRound>>,
    ) -> Result<()> {
        let FirstRound {
            client_first,
            server_first,
        } = match first_round.into() {
            Some(first_round) => first_round,
            None => self.send_client_first(conn, credential, server_api).await?,
        };

        let ClientAuthInfo {
            username,
            password,
            source,
        } = self.client_auth_info(credential)?;

        let server_first = ServerFirst::parse(server_first)?;
        server_first.validate(client_first.nonce.as_str())?;

        let cache_entry_key = CacheEntry {
            password: password.to_string(),
            salt: server_first.salt().to_vec(),
            i: server_first.i(),
            mechanism: self.clone(),
        };
        let (should_update_cache, salted_password) =
            match CREDENTIAL_CACHE.read().await.get(&cache_entry_key) {
                Some(pwd) => (false, pwd.clone()),
                None => (
                    true,
                    self.compute_salted_password(
                        username,
                        password,
                        server_first.i(),
                        server_first.salt(),
                    )?,
                ),
            };

        let client_final = ClientFinal::new(
            source,
            salted_password.as_slice(),
            &client_first,
            &server_first,
            self,
            server_api.cloned(),
        )?;

        let command = client_final.to_command();

        let server_final_response = conn.send_message(command).await?;
        let server_final = ServerFinal::parse(server_final_response.auth_response_body("SCRAM")?)?;
        server_final.validate(salted_password.as_slice(), &client_final, self)?;

        if !server_final.done {
            return Err(Error::authentication_error(
                "SCRAM",
                "expected SCRAM authentication to have completed",
            ));
        }

        if should_update_cache {
            let mut cache = CREDENTIAL_CACHE.write().await;
            if let Entry::Vacant(entry) = cache.entry(cache_entry_key) {
                entry.insert(salted_password);
            }
        }

        Ok(())
    }

    /// HMAC function used as part of SCRAM authentication.
    fn hmac(&self, key: &[u8], input: &[u8]) -> Result<Vec<u8>> {
        let bytes = match self {
            ScramVersion::Sha1 => auth::mac::<Hmac<Sha1>>(key, input, "SCRAM")?
                .as_ref()
                .into(),
            ScramVersion::Sha256 => auth::mac::<Hmac<Sha256>>(key, input, "SCRAM")?
                .as_ref()
                .into(),
        };

        Ok(bytes)
    }

    /// Compute the HMAC of the given key and input and verify it matches the given signature.
    fn hmac_verify(&self, key: &[u8], input: &[u8], signature: &[u8]) -> Result<()> {
        match self {
            ScramVersion::Sha1 => mac_verify::<Hmac<Sha1>>(key, input, signature),
            ScramVersion::Sha256 => mac_verify::<Hmac<Sha256>>(key, input, signature),
        }
    }

    /// The "h" function defined in the SCRAM RFC.
    fn h(&self, str: &[u8]) -> Vec<u8> {
        match self {
            ScramVersion::Sha1 => hash::<Sha1>(str),
            ScramVersion::Sha256 => hash::<Sha256>(str),
        }
    }

    /// The "h_i" function as defined in the SCRAM RFC.
    fn h_i(&self, str: &str, salt: &[u8], iterations: u32) -> Vec<u8> {
        match self {
            ScramVersion::Sha1 => h_i::<Hmac<Sha1>>(str, salt, iterations, 160 / 8),
            ScramVersion::Sha256 => h_i::<Hmac<Sha256>>(str, salt, iterations, 256 / 8),
        }
    }

    /// Computes the salted password according to the SCRAM RFC and the MongoDB specific password
    /// hashing algorithm.
    fn compute_salted_password(
        &self,
        username: &str,
        password: &str,
        i: u32,
        salt: &[u8],
    ) -> Result<Vec<u8>> {
        let normalized_password = match self {
            ScramVersion::Sha1 => {
                // nosemgrep: insecure-hashes
                let mut md5 = Md5::new(); // mongodb rating: No Fix Needed
                md5.update(format!("{username}:mongo:{password}"));
                Cow::Owned(hex::encode(md5.finalize()))
            }
            ScramVersion::Sha256 => match stringprep::saslprep(password) {
                Ok(p) => p,
                Err(_) => {
                    return Err(Error::authentication_error(
                        "SCRAM-SHA-256",
                        "saslprep failure",
                    ))
                }
            },
        };

        Ok(self.h_i(normalized_password.as_ref(), salt, i))
    }
}

impl Display for ScramVersion {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        match self {
            ScramVersion::Sha1 => write!(f, "SCRAM-SHA-1"),
            ScramVersion::Sha256 => write!(f, "SCRAM-SHA-256"),
        }
    }
}

fn xor(lhs: &[u8], rhs: &[u8]) -> Vec<u8> {
    assert_eq!(lhs.len(), rhs.len());

    lhs.iter()
        .zip(rhs.iter())
        .map(|(l, r)| l.bitxor(r))
        .collect()
}

fn mac_verify<M: Mac + KeyInit>(key: &[u8], input: &[u8], signature: &[u8]) -> Result<()> {
    let mut mac = <M as KeyInit>::new_from_slice(key)
        .map_err(|_| Error::unknown_authentication_error("SCRAM"))?;
    mac.update(input);
    match mac.verify_slice(signature) {
        Ok(_) => Ok(()),
        Err(_) => Err(Error::authentication_error(
            "SCRAM",
            "Authentication failed.",
        )),
    }
}

fn hash<D: Digest>(val: &[u8]) -> Vec<u8> {
    let mut hash = D::new();
    hash.update(val);
    hash.finalize().to_vec()
}

fn h_i<M: KeyInit + FixedOutput + Mac + Sync + Clone>(
    str: &str,
    salt: &[u8],
    iterations: u32,
    output_size: usize,
) -> Vec<u8> {
    let mut buf = vec![0u8; output_size];
    pbkdf2::pbkdf2::<M>(str.as_bytes(), salt, iterations, buf.as_mut_slice()).unwrap();
    buf
}

/// Parses a string slice of the form "<expected_key>=<body>" into "<body>", if possible.
fn parse_kvp(str: &str, expected_key: char) -> Result<String> {
    if !str.starts_with(expected_key) || str.chars().nth(1) != Some('=') {
        Err(Error::invalid_authentication_response("SCRAM"))
    } else {
        Ok(str.chars().skip(2).collect())
    }
}

/// Model of the first message sent by the client.
#[derive(Debug)]
pub(crate) struct ClientFirst {
    source: String,

    message: String,

    gs2_header: Range<usize>,

    bare: Range<usize>,

    nonce: String,

    include_db: bool,

    server_api: Option<ServerApi>,
}

impl ClientFirst {
    fn new(source: &str, username: &str, include_db: bool, server_api: Option<ServerApi>) -> Self {
        let nonce = auth::generate_nonce();
        let gs2_header = format!("{NO_CHANNEL_BINDING},,");
        let bare = format!("{USERNAME_KEY}={username},{NONCE_KEY}={nonce}");
        let full = format!("{gs2_header}{bare}");
        let end = full.len();
        ClientFirst {
            source: source.into(),
            message: full,
            gs2_header: Range {
                start: 0,
                end: gs2_header.len(),
            },
            bare: Range {
                start: gs2_header.len(),
                end,
            },
            nonce,
            include_db,
            server_api,
        }
    }

    fn bare_message(&self) -> &str {
        &self.message[self.bare.clone()]
    }

    fn gs2_header(&self) -> &str {
        &self.message[self.gs2_header.clone()]
    }

    fn message(&self) -> &str {
        &self.message[..]
    }

    pub(super) fn to_command(&self, scram: &ScramVersion) -> Result<Command> {
        let payload = self.message().as_bytes().to_vec();
        let auth_mech = AuthMechanism::from_scram_version(scram);
        let sasl_start = SaslStart::new(
            self.source.clone(),
            auth_mech,
            payload,
            self.server_api.clone(),
        );

        let mut cmd = sasl_start.into_command()?;

        if self.include_db {
            cmd.body.append(cstr!("db"), self.source.clone());
        }

        Ok(cmd)
    }
}

/// Model of the first message received from the server.
///
/// This MUST be validated before sending the `ClientFinal` message back to the server.
struct ServerFirst {
    conversation_id: Bson,
    done: bool,
    message: String,
    nonce: String,
    salt: Vec<u8>,
    i: u32,
}

impl ServerFirst {
    fn parse(response: Document) -> Result<Self> {
        let SaslResponse {
            conversation_id,
            payload,
            done,
        } = SaslResponse::parse("SCRAM", response)?;

        let message = str::from_utf8(&payload)
            .map_err(|_| Error::invalid_authentication_response("SCRAM"))?;

        let parts: Vec<&str> = message.split(',').collect();

        if parts.len() < 3 {
            return Err(Error::invalid_authentication_response("SCRAM"));
        };

        let full_nonce = parse_kvp(parts[0], NONCE_KEY)?;

        let salt = base64::decode(parse_kvp(parts[1], SALT_KEY)?.as_str())
            .map_err(|_| Error::invalid_authentication_response("SCRAM"))?;

        let i: u32 = match parse_kvp(parts[2], ITERATION_COUNT_KEY)?.parse() {
            Ok(num) => num,
            Err(_) => {
                return Err(Error::authentication_error(
                    "SCRAM",
                    "iteration count invalid",
                ))
            }
        };

        Ok(ServerFirst {
            conversation_id,
            done,
            message: message.to_string(),
            nonce: full_nonce,
            salt,
            i,
        })
    }

    fn conversation_id(&self) -> &Bson {
        &self.conversation_id
    }

    fn message(&self) -> &str {
        self.message.as_str()
    }

    fn nonce(&self) -> &str {
        self.nonce.as_str()
    }

    fn salt(&self) -> &[u8] {
        self.salt.as_slice()
    }

    fn i(&self) -> u32 {
        self.i
    }

    fn validate(&self, nonce: &str) -> Result<()> {
        if self.done {
            Err(Error::authentication_error(
                "SCRAM",
                "handshake terminated early",
            ))
        } else if !self.nonce.starts_with(nonce) {
            Err(Error::authentication_error("SCRAM", "mismatched nonce"))
        } else if self.i < MIN_ITERATION_COUNT {
            Err(Error::authentication_error(
                "SCRAM",
                "iteration count too low",
            ))
        } else if self.i > MAX_ITERATION_COUNT {
            Err(Error::authentication_error(
                "SCRAM",
                "iteration count too high",
            ))
        } else {
            Ok(())
        }
    }
}

/// Model of the final message sent by the client.
///
/// Contains the "AuthMessage" mentioned in the RFC used in computing the client and server
/// signatures.
struct ClientFinal {
    source: String,
    message: String,
    auth_message: String,
    conversation_id: Bson,
    server_api: Option<ServerApi>,
}

impl ClientFinal {
    fn new(
        source: &str,
        salted_password: &[u8],
        client_first: &ClientFirst,
        server_first: &ServerFirst,
        scram: &ScramVersion,
        server_api: Option<ServerApi>,
    ) -> Result<Self> {
        let client_key = scram.hmac(salted_password, b"Client Key")?;
        let stored_key = scram.h(client_key.as_ref());

        let without_proof = format!(
            "{}={},{}={}",
            CHANNEL_BINDING_KEY,
            base64::encode(client_first.gs2_header()),
            NONCE_KEY,
            server_first.nonce()
        );
        let auth_message = format!(
            "{},{},{}",
            client_first.bare_message(),
            server_first.message(),
            without_proof.as_str()
        );
        let client_signature = scram.hmac(stored_key.as_slice(), auth_message.as_bytes())?;
        let client_proof =
            base64::encode(xor(client_key.as_ref(), client_signature.as_ref()).as_slice());

        let message = format!("{without_proof},{PROOF_KEY}={client_proof}");

        Ok(ClientFinal {
            source: source.into(),
            message,
            auth_message,
            conversation_id: server_first.conversation_id().clone(),
            server_api,
        })
    }

    fn payload(&self) -> Vec<u8> {
        self.message().as_bytes().to_vec()
    }

    fn message(&self) -> &str {
        self.message.as_str()
    }

    fn auth_message(&self) -> &str {
        self.auth_message.as_str()
    }

    fn to_command(&self) -> Command {
        SaslContinue::new(
            self.source.clone(),
            self.conversation_id.clone(),
            self.payload(),
            self.server_api.clone(),
        )
        .into_command()
    }
}

enum ServerFinalBody {
    Error(String),
    Verifier(String),
}

/// Model of the final message received from the server.
///
/// This MUST be validated before sending the final no-op message to the server.
struct ServerFinal {
    conversation_id: Bson,
    done: bool,
    body: ServerFinalBody,
}

impl ServerFinal {
    fn parse(response: Document) -> Result<Self> {
        let SaslResponse {
            conversation_id,
            payload,
            done,
        } = SaslResponse::parse("SCRAM", response)?;

        let message = str::from_utf8(&payload)
            .map_err(|_| Error::invalid_authentication_response("SCRAM"))?;

        let first = message
            .chars()
            .next()
            .ok_or_else(|| Error::invalid_authentication_response("SCRAM"))?;
        let body = if first == ERROR_KEY {
            let error = parse_kvp(message, ERROR_KEY)?;
            ServerFinalBody::Error(error)
        } else if first == VERIFIER_KEY {
            let verifier = parse_kvp(message, VERIFIER_KEY)?;
            ServerFinalBody::Verifier(verifier)
        } else {
            return Err(Error::invalid_authentication_response("SCRAM"));
        };

        Ok(ServerFinal {
            conversation_id,
            done,
            body,
        })
    }

    fn validate(
        &self,
        salted_password: &[u8],
        client_final: &ClientFinal,
        scram: &ScramVersion,
    ) -> Result<()> {
        if self.conversation_id != client_final.conversation_id {
            return Err(Error::authentication_error(
                "SCRAM",
                "mismatched conversationId's",
            ));
        };

        match self.body {
            ServerFinalBody::Verifier(ref body) => {
                let server_key = scram.hmac(salted_password, b"Server Key")?;
                let body_decoded = base64::decode(body.as_bytes())
                    .map_err(|_| Error::invalid_authentication_response("SCRAM"))?;

                scram.hmac_verify(
                    server_key.as_ref(),
                    client_final.auth_message().as_bytes(),
                    body_decoded.as_slice(),
                )
            }
            ServerFinalBody::Error(ref err) => {
                Err(Error::authentication_error("SCRAM", err.as_str()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::bson::Bson;

    use super::ServerFirst;

    #[test]
    fn test_iteration_count() {
        let nonce = "mocked";

        let invalid_iteration_count = ServerFirst {
            conversation_id: Bson::Null,
            done: false,
            message: "mocked".to_string(),
            nonce: nonce.to_string(),
            salt: Vec::new(),
            i: 42,
        };
        assert!(invalid_iteration_count.validate(nonce).is_err());

        let valid_iteration_count = ServerFirst {
            i: 4096,
            ..invalid_iteration_count
        };
        assert!(valid_iteration_count.validate(nonce).is_ok());

        let max_allowed_iteration_count = ServerFirst {
            i: 100_000,
            ..valid_iteration_count
        };
        assert!(max_allowed_iteration_count.validate(nonce).is_ok());

        let too_high_iteration_count = ServerFirst {
            i: 100_001,
            ..max_allowed_iteration_count
        };
        assert!(too_high_iteration_count.validate(nonce).is_err());
    }

    fn server_first_with_nonce(nonce: &str) -> ServerFirst {
        ServerFirst {
            conversation_id: Bson::Null,
            done: false,
            message: "mocked".to_string(),
            nonce: nonce.to_string(),
            salt: Vec::new(),
            i: 4096,
        }
    }

    #[test]
    fn test_nonce_prefix_matches() {
        let server_first = server_first_with_nonce("client-nonceserver-suffix");
        assert!(server_first.validate("client-nonce").is_ok());
    }

    #[test]
    fn test_nonce_mismatch_is_rejected() {
        let server_first = server_first_with_nonce("server-nonce");
        assert!(server_first.validate("client-nonce").is_err());
    }

    #[test]
    fn test_client_nonce_longer_than_server_nonce_is_rejected_not_a_panic() {
        let server_first = server_first_with_nonce("short");
        assert!(server_first.validate("this-nonce-is-longer-than-the-server-echoed-back").is_err());
    }
}
