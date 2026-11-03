use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::client::{AuthResult, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::AgentIdentity;
use russh::keys::ssh_key::public::KeyData;
use russh::keys::ssh_key::{Algorithm, Certificate, HashAlg, PrivateKey, PublicKey};
use russh::{MethodKind, MethodSet};
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::PromptReason;
use tablepro_core::{SshFailure, TransportError};

use super::agent::{Agent, AgentSlot, identity_algorithm, signs_for};
use super::failure::from_russh;
use super::handler::{HopHandler, SessionEnd};
use super::identity::{self, FileSignError, FileSigner, TRIES};
use super::prompts::Prompts;
use super::services::InProcessSsh;
use crate::SshAuth;

// A server re-asking after a wrong answer gets this many rounds before the method is given up.
const KEYBOARD_ROUNDS: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Method {
    Password,
    KeyboardInteractive,
    Agent,
    KeyFile(PathBuf),
    DefaultKeyFiles,
}

impl Method {
    fn kind(&self) -> MethodKind {
        match self {
            Self::Password => MethodKind::Password,
            Self::KeyboardInteractive => MethodKind::KeyboardInteractive,
            Self::Agent | Self::KeyFile(_) | Self::DefaultKeyFiles => MethodKind::PublicKey,
        }
    }
}

// The order the OpenSSH transport's PreferredAuthentications and identities give.
pub(crate) fn destination_methods(auth: &SshAuth) -> Vec<Method> {
    use Method::{Agent, DefaultKeyFiles, KeyFile, KeyboardInteractive, Password};
    match auth {
        SshAuth::Password { .. } => vec![Password, KeyboardInteractive, Agent, DefaultKeyFiles],
        SshAuth::KeyboardInteractive => vec![KeyboardInteractive, Password, Agent, DefaultKeyFiles],
        SshAuth::PrivateKey { path: Some(path), .. } => vec![KeyFile(path.clone()), KeyboardInteractive, Password],
        SshAuth::Agent | SshAuth::PrivateKey { path: None, .. } => {
            vec![Agent, DefaultKeyFiles, KeyboardInteractive, Password]
        }
    }
}

// A jump host has no fields of its own, so it tries what OpenSSH would, plus the connection's key file.
pub(crate) fn hop_methods(auth: &SshAuth) -> Vec<Method> {
    let mut methods = vec![Method::Agent];
    if let SshAuth::PrivateKey { path: Some(path), .. } = auth {
        methods.push(Method::KeyFile(path.clone()));
    }
    methods.extend([Method::DefaultKeyFiles, Method::KeyboardInteractive, Method::Password]);
    methods
}

enum Step {
    Done,
    Partial(MethodSet),
    Refused(MethodSet),
    NotTried,
}

impl From<AuthResult> for Step {
    fn from(result: AuthResult) -> Self {
        match result {
            AuthResult::Success => Self::Done,
            AuthResult::Failure {
                remaining_methods,
                partial_success: true,
            } => Self::Partial(remaining_methods),
            AuthResult::Failure { remaining_methods, .. } => Self::Refused(remaining_methods),
        }
    }
}

// A key, or a certificate for it, offered once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Offered {
    Key(KeyData),
    Certificate(Box<Certificate>),
}

impl Offered {
    fn of(identity: &AgentIdentity) -> Self {
        match identity {
            AgentIdentity::PublicKey { key, .. } => Self::Key(key.key_data().clone()),
            AgentIdentity::Certificate { certificate, .. } => Self::Certificate(Box::new(certificate.clone())),
        }
    }
}

pub(crate) struct Login<'a> {
    pub user: &'a str,
    pub host: &'a str,
    // Only the destination's; a jump host is never handed it.
    pub password: Option<SecretString>,
    // The connection names the agent, so its absence is the reason a login failed.
    pub agent_chosen: bool,
    pub passphrase: &'a mut Option<SecretString>,
    // A key file opened for one hop serves the next without its passphrase again.
    pub keys: &'a mut HashMap<PathBuf, Arc<PrivateKey>>,
    // Keys already offered to this hop, so a second round after a partial success offers the rest.
    pub offered: Vec<Offered>,
    pub agent: &'a mut AgentSlot,
    pub services: &'a InProcessSsh,
    pub prompts: &'a Prompts,
    pub end: &'a SessionEnd,
}

impl Login<'_> {
    fn failed(&self, error: russh::Error) -> TransportError {
        from_russh(error, self.host, self.end)
    }

    fn user_host(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }
}

pub(crate) async fn log_in(
    handle: &mut Handle<HopHandler>,
    methods: &[Method],
    login: &mut Login<'_>,
) -> Result<(), TransportError> {
    let mut allowed = match handle
        .authenticate_none(login.user)
        .await
        .map_err(|error| login.failed(error))?
    {
        AuthResult::Success => return Ok(()),
        AuthResult::Failure { remaining_methods, .. } => remaining_methods,
    };
    let mut used = vec![false; methods.len()];
    'rounds: loop {
        for (index, method) in methods.iter().enumerate() {
            if used[index] || !allowed.contains(&method.kind()) {
                continue;
            }
            used[index] = true;
            match try_method(handle, method, login).await? {
                Step::Done => return Ok(()),
                // The server wants another method too, so earlier ones it now lists get their turn, and
                // the agent and default identities their keys not yet offered.
                Step::Partial(remaining) => {
                    allowed = remaining;
                    for (index, method) in methods.iter().enumerate() {
                        if matches!(method, Method::Agent | Method::DefaultKeyFiles) {
                            used[index] = false;
                        }
                    }
                    continue 'rounds;
                }
                Step::Refused(remaining) => allowed = remaining,
                Step::NotTried => {}
            }
        }
        break;
    }
    // A server that ends the login, as on MaxAuthTries, says why in its disconnect.
    if handle.is_closed() || login.end.closed().is_cancelled() {
        return Err(login.failed(russh::Error::Disconnect));
    }
    if login.agent_chosen
        && let Some(location) = login.agent.unavailable()
    {
        return Err(SshFailure::AgentUnavailable {
            location: location.to_owned(),
        }
        .into());
    }
    Err(SshFailure::AuthenticationRejected {
        user: login.user.to_owned(),
        host: login.host.to_owned(),
        methods: allowed.iter().map(|kind| <&str>::from(kind).to_owned()).collect(),
    }
    .into())
}

async fn try_method(
    handle: &mut Handle<HopHandler>,
    method: &Method,
    login: &mut Login<'_>,
) -> Result<Step, TransportError> {
    match method {
        Method::Password => password(handle, login).await,
        Method::KeyboardInteractive => keyboard_interactive(handle, login).await,
        Method::Agent => agent(handle, login, None).await,
        Method::KeyFile(path) => key_file(handle, path, true, login).await,
        Method::DefaultKeyFiles => {
            let mut last = Step::NotTried;
            for path in login.services.identity_files.clone() {
                if !tokio::fs::try_exists(&path).await.unwrap_or(false) {
                    continue;
                }
                match key_file(handle, &path, false, login).await? {
                    Step::Refused(remaining) if remaining.contains(&MethodKind::PublicKey) => {
                        last = Step::Refused(remaining);
                    }
                    Step::NotTried => {}
                    other => return Ok(other),
                }
            }
            Ok(last)
        }
    }
}

async fn password(handle: &mut Handle<HopHandler>, login: &mut Login<'_>) -> Result<Step, TransportError> {
    let mut reason = PromptReason::NotStored;
    let mut last = Step::NotTried;
    for _ in 0..TRIES {
        let secret = match login.password.take() {
            Some(stored) => stored,
            None => match login.prompts.password(&login.user_host(), reason.clone()).await? {
                Some(typed) => typed,
                None => return Ok(last),
            },
        };
        let result = handle
            .authenticate_password(login.user, secret.expose_secret())
            .await
            .map_err(|error| login.failed(error))?;
        match Step::from(result) {
            Step::Refused(remaining) => {
                reason = PromptReason::Rejected;
                let again = remaining.contains(&MethodKind::Password);
                last = Step::Refused(remaining);
                if !again {
                    break;
                }
            }
            other => return Ok(other),
        }
    }
    Ok(last)
}

// A rejected exchange starts again, as a wrong password does, while someone can answer.
async fn keyboard_interactive(handle: &mut Handle<HopHandler>, login: &mut Login<'_>) -> Result<Step, TransportError> {
    let mut last = Step::NotTried;
    for _ in 0..TRIES {
        let (step, asked) = keyboard_exchange(handle, login).await?;
        match step {
            Step::Refused(remaining) => {
                let again = asked && remaining.contains(&MethodKind::KeyboardInteractive);
                last = Step::Refused(remaining);
                if !again {
                    break;
                }
            }
            other => return Ok(other),
        }
    }
    Ok(last)
}

// One exchange, and whether a person gave its answers.
async fn keyboard_exchange(
    handle: &mut Handle<HopHandler>,
    login: &mut Login<'_>,
) -> Result<(Step, bool), TransportError> {
    let mut asked = false;
    let mut response = handle
        .authenticate_keyboard_interactive_start(login.user, None)
        .await
        .map_err(|error| login.failed(error))?;
    let mut rounds = 0;
    loop {
        let (name, instructions, prompts) = match response {
            KeyboardInteractiveAuthResponse::Success => return Ok((Step::Done, asked)),
            KeyboardInteractiveAuthResponse::Failure {
                remaining_methods,
                partial_success,
            } => {
                let step = match partial_success {
                    true => Step::Partial(remaining_methods),
                    false => Step::Refused(remaining_methods),
                };
                return Ok((step, asked));
            }
            KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => (name, instructions, prompts),
        };
        rounds += 1;
        if rounds > KEYBOARD_ROUNDS {
            return Err(SshFailure::Protocol {
                status: None,
                detail: format!("keyboard-interactive asked more than {KEYBOARD_ROUNDS} times"),
            }
            .into());
        }
        let answers = if prompts.is_empty() {
            Vec::new()
        } else if let Some(stored) = stored_password_answer(&prompts, login) {
            vec![stored]
        } else {
            match login
                .prompts
                .keyboard_interactive(&login.user_host(), &name, &instructions, &prompts)
                .await?
            {
                Some(answers) => {
                    asked = true;
                    answers
                }
                // russh takes nothing but answers until the exchange ends, so nobody to ask answers blank.
                None => prompts.iter().map(|_| SecretString::from("")).collect(),
            }
        };
        let answers = answers.iter().map(|answer| answer.expose_secret().to_owned()).collect();
        response = handle
            .authenticate_keyboard_interactive_respond(answers)
            .await
            .map_err(|error| login.failed(error))?;
    }
}

// PAM asks for the password through keyboard-interactive, so the stored one answers its one hidden prompt.
fn stored_password_answer(prompts: &[russh::client::Prompt], login: &mut Login<'_>) -> Option<SecretString> {
    let [prompt] = prompts else {
        return None;
    };
    if prompt.echo || !prompt.prompt.to_ascii_lowercase().contains("password") {
        return None;
    }
    login.password.take()
}

// `only` limits the agent to one key, the connection's key file.
async fn agent(
    handle: &mut Handle<HopHandler>,
    login: &mut Login<'_>,
    only: Option<&PublicKey>,
) -> Result<Step, TransportError> {
    let (user, host, end) = (login.user, login.host, login.end);
    let Some((agent, identities)) = login.agent.session(login.services).await else {
        return Ok(Step::NotTried);
    };
    let wanted: Vec<AgentIdentity> = identities
        .iter()
        .filter(|identity| only.is_none_or(|key| signs_for(identity, key)))
        .filter(|identity| !login.offered.contains(&Offered::of(identity)))
        .cloned()
        .collect();
    let mut last = Step::NotTried;
    for identity in wanted {
        let offered = Offered::of(&identity);
        let hash = rsa_hash(handle, identity_algorithm(&identity)).await;
        let result = match identity {
            AgentIdentity::PublicKey { key, .. } => handle.authenticate_publickey_with(user, key, hash, agent).await,
            AgentIdentity::Certificate { certificate, .. } => {
                handle
                    .authenticate_certificate_with(user, certificate, hash, agent)
                    .await
            }
        };
        let result = match result {
            // A key the agent could not sign with was not offered, so its file may still be.
            Ok(result) => {
                login.offered.push(offered);
                result
            }
            Err(error) if handle.is_closed() => {
                tracing::debug!(%error, "the session ended while the agent signed");
                return Err(from_russh(russh::Error::Disconnect, host, end));
            }
            Err(error) => {
                tracing::debug!(%error, "the agent did not sign");
                continue;
            }
        };
        match Step::from(result) {
            Step::Refused(remaining) => {
                let more = remaining.contains(&MethodKind::PublicKey);
                last = Step::Refused(remaining);
                if !more {
                    break;
                }
            }
            other => return Ok(other),
        }
    }
    Ok(last)
}

async fn key_file(
    handle: &mut Handle<HopHandler>,
    path: &Path,
    chosen: bool,
    login: &mut Login<'_>,
) -> Result<Step, TransportError> {
    let certificate = identity::certificate_beside(path).await;
    let public = identity::public_half(path).await;
    // A key the agent holds signs there with no passphrase, certificates included (Linux ADR 0020).
    if let Some(public) = &public
        && login.agent.holds(login.services, public).await
    {
        if let Some(certificate) = &certificate
            && !login
                .offered
                .contains(&Offered::Certificate(Box::new(certificate.clone())))
        {
            match agent_certificate(handle, login, certificate).await? {
                Step::NotTried => {}
                Step::Refused(remaining) if remaining.contains(&MethodKind::PublicKey) => {
                    login.offered.push(Offered::Certificate(Box::new(certificate.clone())));
                }
                other => return Ok(other),
            }
        }
        let step = agent(handle, login, Some(public)).await?;
        if !matches!(step, Step::NotTried) {
            return Ok(step);
        }
    }
    let (user, host, end) = (login.user, login.host, login.end);
    let mut signer = FileSigner {
        path,
        chosen,
        stored: &mut *login.passphrase,
        prompts: login.prompts,
        keys: &mut *login.keys,
    };
    // A PEM or PKCS#8 file with no `.pub` beside it shows its public half only once opened.
    let public = match public {
        Some(public) => public,
        None => match signer.key().await? {
            Some(key) => key.public_key().clone(),
            None => return Ok(Step::NotTried),
        },
    };
    if let Some(certificate) = certificate
        && !login
            .offered
            .contains(&Offered::Certificate(Box::new(certificate.clone())))
    {
        let hash = rsa_hash(handle, certificate.public_key().algorithm()).await;
        let offered = Offered::Certificate(Box::new(certificate.clone()));
        let result = handle
            .authenticate_certificate_with(user, certificate, hash, &mut signer)
            .await;
        match signed(result, host, end)? {
            Step::NotTried => {}
            Step::Refused(remaining) if remaining.contains(&MethodKind::PublicKey) => login.offered.push(offered),
            other => return Ok(other),
        }
    }
    let offered = Offered::Key(public.key_data().clone());
    if login.offered.contains(&offered) {
        return Ok(Step::NotTried);
    }
    let hash = rsa_hash(handle, public.algorithm()).await;
    let mut signer = FileSigner {
        path,
        chosen,
        stored: &mut *login.passphrase,
        prompts: login.prompts,
        keys: &mut *login.keys,
    };
    let result = handle
        .authenticate_publickey_with(user, public, hash, &mut signer)
        .await;
    let step = signed(result, host, end)?;
    if !matches!(step, Step::NotTried) {
        login.offered.push(offered);
    }
    Ok(step)
}

// A key nobody could open was never offered; a cancel or an unusable file ends the login.
fn signed(result: Result<AuthResult, FileSignError>, host: &str, end: &SessionEnd) -> Result<Step, TransportError> {
    match result {
        Ok(result) => Ok(Step::from(result)),
        Err(FileSignError::Failure(failure)) => Err(failure.into()),
        Err(FileSignError::Unanswered) => Ok(Step::NotTried),
        Err(FileSignError::Send(_)) => Err(from_russh(russh::Error::Disconnect, host, end)),
        Err(FileSignError::Agent(error)) => {
            tracing::debug!(%error, "the key file did not sign");
            Ok(Step::NotTried)
        }
    }
}

// An agent that holds only the plain key does not know the certificate on disk, so it is asked to
// sign as that key, which is the signature a certificate login carries, as OpenSSH asks it.
struct AsPlainKey<'a>(&'a mut Agent);

impl russh::Signer for AsPlainKey<'_> {
    type Error = russh::AgentAuthError;

    async fn auth_sign(
        &mut self,
        identity: &AgentIdentity,
        hash_alg: Option<HashAlg>,
        to_sign: Vec<u8>,
    ) -> Result<Vec<u8>, Self::Error> {
        let plain = match identity {
            AgentIdentity::Certificate { certificate, comment } => AgentIdentity::PublicKey {
                key: PublicKey::from(certificate.public_key().clone()),
                comment: comment.clone(),
            },
            other @ AgentIdentity::PublicKey { .. } => other.clone(),
        };
        russh::Signer::auth_sign(self.0, &plain, hash_alg, to_sign).await
    }
}

// The agent signs with the key a certificate kept on disk certifies.
async fn agent_certificate(
    handle: &mut Handle<HopHandler>,
    login: &mut Login<'_>,
    certificate: &Certificate,
) -> Result<Step, TransportError> {
    let (user, host, end) = (login.user, login.host, login.end);
    let Some((agent, _)) = login.agent.session(login.services).await else {
        return Ok(Step::NotTried);
    };
    let hash = rsa_hash(handle, certificate.public_key().algorithm()).await;
    match handle
        .authenticate_certificate_with(user, certificate.clone(), hash, &mut AsPlainKey(agent))
        .await
    {
        Ok(result) => Ok(Step::from(result)),
        Err(error) if handle.is_closed() => {
            tracing::debug!(%error, "the session ended while the agent signed");
            Err(from_russh(russh::Error::Disconnect, host, end))
        }
        Err(error) => {
            tracing::debug!(%error, "the agent did not sign the certificate");
            Ok(Step::NotTried)
        }
    }
}

// rsa-sha2-512 or -256 when the server lists one, and ssh-rsa only for a server that names none.
async fn rsa_hash(handle: &Handle<HopHandler>, algorithm: Algorithm) -> Option<HashAlg> {
    if !algorithm.is_rsa() {
        return None;
    }
    handle.best_supported_rsa_hash().await.ok().flatten().flatten()
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;

    use super::*;

    #[test]
    fn each_auth_tries_methods_in_the_order_the_openssh_transport_does() {
        let key = PathBuf::from("/keys/id_ed25519");
        let password = SshAuth::Password {
            password: SecretString::from("s3cret"),
        };
        let chosen = SshAuth::PrivateKey {
            path: Some(key.clone()),
            passphrase: None,
        };

        assert_eq!(
            destination_methods(&password),
            [
                Method::Password,
                Method::KeyboardInteractive,
                Method::Agent,
                Method::DefaultKeyFiles
            ]
        );
        assert_eq!(
            destination_methods(&chosen),
            [
                Method::KeyFile(key.clone()),
                Method::KeyboardInteractive,
                Method::Password
            ]
        );
        assert_eq!(
            destination_methods(&SshAuth::Agent),
            [
                Method::Agent,
                Method::DefaultKeyFiles,
                Method::KeyboardInteractive,
                Method::Password
            ]
        );
        assert_eq!(
            hop_methods(&chosen),
            [
                Method::Agent,
                Method::KeyFile(key),
                Method::DefaultKeyFiles,
                Method::KeyboardInteractive,
                Method::Password
            ]
        );
        assert_eq!(hop_methods(&password)[0], Method::Agent);
    }
}
