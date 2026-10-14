use futures::future::BoxFuture;
use secrecy::SecretString;
use tablepro_core::Credentials;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretSave};
use tablepro_ssh::SshAuth;
use tablepro_storage::{CredentialDemand, KeyringCredentials, ResolvedSecret};

use super::{ConnectError, ConnectRequest, CredentialSource, RefreshedRequest, RequestTarget};

/// Every secret the request logs in with is read from the keyring again,
/// so a password fixed in Seahorse is the one the next attempt uses.
impl CredentialSource for KeyringCredentials {
    fn refresh(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
        let credentials = self.clone();
        Box::pin(async move {
            let mut request = request;
            let mut typed = Typed::default();
            let RequestTarget::Network {
                credentials: login,
                ssh,
                ..
            } = &mut request.target
            else {
                return Ok(RefreshedRequest::unchanged(request));
            };
            if let Credentials::Password { password, .. } = login {
                let resolved = credentials
                    .resolve(SecretKind::DatabasePassword, Some(password), &interaction, demand)
                    .await?;
                fill(password, SecretKind::DatabasePassword, resolved, &mut typed);
            }
            if let Some(ssh) = ssh {
                match &mut ssh.auth {
                    SshAuth::Password { password } => {
                        let resolved = credentials
                            .resolve(SecretKind::SshPassword, Some(password), &interaction, demand)
                            .await?;
                        fill(password, SecretKind::SshPassword, resolved, &mut typed);
                    }
                    SshAuth::PrivateKey { passphrase, .. } => {
                        let resolved = credentials
                            .resolve(SecretKind::SshPassphrase, passphrase.as_ref(), &interaction, demand)
                            .await?;
                        if let Some(resolved) = resolved {
                            *passphrase = Some(typed.note(SecretKind::SshPassphrase, resolved));
                        }
                    }
                    SshAuth::Agent | SshAuth::KeyboardInteractive => {}
                }
            }
            Ok(RefreshedRequest {
                request,
                remember: typed.remember,
                typed: typed.kinds,
            })
        })
    }

    fn remember(&self, saves: Vec<SecretSave>) -> BoxFuture<'static, Vec<(SecretKind, SecretError)>> {
        let secrets = self.secrets().clone();
        let id = self.connection_id();
        Box::pin(async move {
            let mut failed = Vec::new();
            for save in saves {
                if let Err(error) = secrets.store(id, save.kind, &save.secret, &save.label).await {
                    failed.push((save.kind, error));
                }
            }
            failed
        })
    }
}

/// What the user typed while one request was refreshed.
#[derive(Default)]
struct Typed {
    remember: Vec<SecretSave>,
    kinds: Vec<SecretKind>,
}

impl Typed {
    fn note(&mut self, kind: SecretKind, resolved: ResolvedSecret) -> SecretString {
        self.remember.extend(resolved.remember);
        if resolved.typed {
            self.kinds.push(kind);
        }
        resolved.secret
    }
}

fn fill(slot: &mut SecretString, kind: SecretKind, resolved: Option<ResolvedSecret>, typed: &mut Typed) {
    if let Some(resolved) = resolved {
        *slot = typed.note(kind, resolved);
    }
}
