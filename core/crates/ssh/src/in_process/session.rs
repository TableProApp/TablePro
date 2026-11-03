use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::Arc;

use russh::Preferred;
use russh::client::{Config, Handle};
use russh::keys::ssh_key::Algorithm;
use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, SshDestinationPart, SshDestinationProblem, SshFailure, TimeoutPhase, Transport,
    TransportError, TransportStream,
};
use tablepro_net::DirectTcpTransport;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use super::abortable::Abortable;
use super::agent::AgentSlot;
use super::auth::{Login, destination_methods, hop_methods, log_in};
use super::clock::PromptClock;
use super::failure::{channel_failure, ended, from_russh};
use super::forward::InProcessForward;
use super::handler::{HopHandler, HostKeyCheck, SessionEnd};
use super::known_hosts::KnownTypes;
use super::prompts::Prompts;
use super::services::InProcessSsh;
use crate::{SshAuth, SshConfig, SshDestination};

const SSH_PORT: u16 = 22;

// One SSH session in this process: the jump hosts' sessions, each carried
// over the one before, and the destination's last.
pub struct InProcessSession {
    destination: String,
    first_hop: NetworkEndpoint,
    hops: Vec<Arc<Handle<HopHandler>>>,
    end: Arc<SessionEnd>,
}

impl std::fmt::Debug for InProcessSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InProcessSession")
            .field("destination", &self.destination)
            .field("hops", &self.hops.len())
            .finish_non_exhaustive()
    }
}

struct Hop<'a> {
    destination: &'a SshDestination,
    user: String,
    port: u16,
}

impl<'a> Hop<'a> {
    fn new(destination: &'a SshDestination) -> Result<Self, SshFailure> {
        let user = match destination.user() {
            Some(user) => user.to_owned(),
            None => local_user().ok_or(SshDestinationProblem::Empty {
                part: SshDestinationPart::User,
            })?,
        };
        Ok(Self {
            destination,
            user,
            port: destination.port().unwrap_or(SSH_PORT),
        })
    }

    fn host(&self) -> &str {
        self.destination.host()
    }
}

// ssh logs in as the local user when none is named.
fn local_user() -> Option<String> {
    ["USER", "LOGNAME", "USERNAME"]
        .into_iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

impl InProcessSession {
    pub async fn connect(
        config: &SshConfig,
        services: &InProcessSsh,
        liveness: &LivenessPolicy,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> Result<Arc<Self>, TransportError> {
        let clock = Arc::new(PromptClock::new(liveness.ssh_handshake_timeout));
        // Ends the half-built chain's streams and open questions when the connect does not finish.
        let abort = CancellationToken::new();
        let unfinished = abort.clone().drop_guard();
        let prompts = Arc::new(Prompts::new(
            interaction,
            clock.clone(),
            config.destination.to_string(),
            abort.clone(),
        ));
        let connected = tokio::select! {
            biased;
            () = cancel.cancelled() => Err(SshFailure::InteractionCancelled.into()),
            connected = Self::connect_chain(config, services, liveness, prompts, &abort) => connected,
            () = clock.expired() => Err(TransportError::Timeout { phase: TimeoutPhase::SshHandshake }),
        };
        if connected.is_ok() {
            unfinished.disarm();
        }
        connected.map(Arc::new)
    }

    async fn connect_chain(
        config: &SshConfig,
        services: &InProcessSsh,
        liveness: &LivenessPolicy,
        prompts: Arc<Prompts>,
        abort: &CancellationToken,
    ) -> Result<Self, TransportError> {
        let route: Vec<Hop<'_>> = config
            .jump_hosts
            .iter()
            .chain([&config.destination])
            .map(Hop::new)
            .collect::<Result<_, _>>()?;
        let first_hop = endpoint(&route[0])?;
        let end = Arc::new(SessionEnd::default());
        let mut passphrase = match &config.auth {
            SshAuth::PrivateKey { passphrase, .. } => passphrase.clone(),
            SshAuth::Agent | SshAuth::Password { .. } | SshAuth::KeyboardInteractive => None,
        };
        let mut keys = HashMap::new();
        let mut hops: Vec<Arc<Handle<HopHandler>>> = Vec::with_capacity(route.len());
        for (index, hop) in route.iter().enumerate() {
            let is_destination = index + 1 == route.len();
            let stream = match hops.last() {
                None => DirectTcpTransport::new(first_hop.clone(), liveness).open().await?,
                Some(previous) => open_next_hop(previous, hop, &end).await?,
            };
            let stream = Box::new(Abortable::new(stream, abort.clone()));
            let mut handle = handshake(stream, hop, services, liveness, &prompts, &end).await?;
            let mut agent = AgentSlot::new(handle.agent_session_binding().cloned());
            let (methods, password) = match is_destination {
                true => (destination_methods(&config.auth), stored_password(&config.auth)),
                false => (hop_methods(&config.auth), None),
            };
            let mut login = Login {
                user: &hop.user,
                host: hop.host(),
                password,
                agent_chosen: is_destination && matches!(config.auth, SshAuth::Agent),
                passphrase: &mut passphrase,
                keys: &mut keys,
                offered: Vec::new(),
                agent: &mut agent,
                services,
                prompts: &prompts,
                end: &end,
            };
            log_in(&mut handle, &methods, &mut login).await?;
            hops.push(Arc::new(handle));
        }
        Ok(Self {
            destination: config.destination.to_string(),
            first_hop,
            hops,
            end,
        })
    }

    pub fn closed(&self) -> WaitForCancellationFutureOwned {
        self.end.closed().clone().cancelled_owned()
    }

    pub fn is_closed(&self) -> bool {
        self.end.closed().is_cancelled()
    }

    pub fn destination(&self) -> &str {
        &self.destination
    }

    pub fn first_hop_endpoint(&self) -> &NetworkEndpoint {
        &self.first_hop
    }

    pub async fn forward(
        self: &Arc<Self>,
        target: NetworkEndpoint,
        liveness: &LivenessPolicy,
    ) -> Result<Arc<dyn Transport>, TransportError> {
        if self.is_closed() {
            return Err(ended(&self.end));
        }
        Ok(Arc::new(InProcessForward::new(self.clone(), target, liveness)))
    }

    pub(crate) async fn open_channel(
        &self,
        target: &NetworkEndpoint,
    ) -> Result<Box<dyn TransportStream>, TransportError> {
        let Some(destination) = self.hops.last() else {
            return Err(ended(&self.end));
        };
        match destination
            .channel_open_direct_tcpip(target.host(), u32::from(target.port()), "127.0.0.1", 0)
            .await
        {
            Ok(channel) => Ok(Box::new(channel.into_stream())),
            Err(_) if self.is_closed() => Err(ended(&self.end)),
            Err(russh::Error::ChannelOpenFailure(reason)) => Err(SshFailure::ChannelOpenFailed {
                target: target.to_string(),
                detail: channel_failure(&reason),
            }
            .into()),
            Err(error) => Err(SshFailure::ChannelOpenFailed {
                target: target.to_string(),
                detail: error.to_string(),
            }
            .into()),
        }
    }

    pub(crate) fn ended(&self) -> TransportError {
        ended(&self.end)
    }
}

impl Drop for InProcessSession {
    fn drop(&mut self) {
        self.end.closed().cancel();
        let hops = std::mem::take(&mut self.hops);
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        // The destination says goodbye first, then each jump host, as ssh closes a chain.
        runtime.spawn(async move {
            for hop in hops.iter().rev() {
                if let Err(error) = hop.disconnect(russh::Disconnect::ByApplication, "", "en").await {
                    tracing::debug!(%error, "an SSH session was already closed");
                }
            }
        });
    }
}

// known_hosts files an RSA key as ssh-rsa, which signs as rsa-sha2-256 and -512 too.
fn same_key_type(held: &Algorithm, offered: &Algorithm) -> bool {
    match (held, offered) {
        (Algorithm::Rsa { .. }, Algorithm::Rsa { .. }) => true,
        _ => held == offered,
    }
}

fn endpoint(hop: &Hop<'_>) -> Result<NetworkEndpoint, SshFailure> {
    NetworkEndpoint::new(hop.host(), hop.port).map_err(|_| {
        SshFailure::from(SshDestinationProblem::Empty {
            part: SshDestinationPart::Host,
        })
    })
}

async fn open_next_hop(
    previous: &Handle<HopHandler>,
    hop: &Hop<'_>,
    end: &SessionEnd,
) -> Result<Box<dyn TransportStream>, TransportError> {
    let target = format!("{}:{}", hop.host(), hop.port);
    match previous
        .channel_open_direct_tcpip(hop.host(), u32::from(hop.port), "127.0.0.1", 0)
        .await
    {
        Ok(channel) => Ok(Box::new(channel.into_stream())),
        Err(russh::Error::ChannelOpenFailure(reason)) => Err(SshFailure::ChannelOpenFailed {
            target,
            detail: channel_failure(&reason),
        }
        .into()),
        Err(error) => Err(from_russh(error, hop.host(), end)),
    }
}

// The host key types known_hosts holds for the hop go first, as OpenSSH orders them, so a host
// known by one type is not asked about as new because the server prefers another.
async fn handshake(
    stream: Box<Abortable>,
    hop: &Hop<'_>,
    services: &InProcessSsh,
    liveness: &LivenessPolicy,
    prompts: &Arc<Prompts>,
    end: &Arc<SessionEnd>,
) -> Result<Handle<HopHandler>, TransportError> {
    let check = Arc::new(HostKeyCheck::new(services, hop.host(), hop.port, prompts.clone()));
    let known = check.known_types().await;
    let handler = HopHandler {
        check: check.clone(),
        end: end.clone(),
    };
    russh::client::connect_stream(Arc::new(russh_config(liveness, &known)), stream, handler)
        .await
        .map_err(|error| match check.take_refusal() {
            Some(refusal) => refusal.into(),
            None => from_russh(error, hop.host(), end),
        })
}

fn stored_password(auth: &SshAuth) -> Option<SecretString> {
    match auth {
        SshAuth::Password { password } => Some(password.clone()),
        SshAuth::Agent | SshAuth::PrivateKey { .. } | SshAuth::KeyboardInteractive => None,
    }
}

// ServerAliveInterval and ServerAliveCountMax as the OpenSSH transport passes them.
fn russh_config(liveness: &LivenessPolicy, known: &KnownTypes) -> Config {
    let mut preferred = Preferred::default();
    let (first, rest): (Vec<Algorithm>, Vec<Algorithm>) = preferred
        .key
        .iter()
        .cloned()
        .partition(|offered| known.plain.iter().any(|held| same_key_type(held, offered)));
    preferred.key = Cow::Owned(first.into_iter().chain(rest).collect());
    // A server's certificate is checked against @cert-authority lines, so it is asked for only where one names the host.
    if known.authority {
        preferred.host_key_certificates = preferred.key.clone();
    }
    Config {
        preferred,
        keepalive_interval: Some(liveness.ssh_keepalive_interval),
        keepalive_max: usize::try_from(liveness.ssh_keepalive_max).unwrap_or(usize::MAX),
        inactivity_timeout: None,
        nodelay: true,
        ..Config::default()
    }
}

#[cfg(test)]
mod tests {
    use russh::keys::ssh_key::EcdsaCurve;

    use super::*;

    #[test]
    fn keepalives_follow_the_liveness_policy() {
        let config = russh_config(&LivenessPolicy::DESKTOP, &KnownTypes::default());

        assert_eq!(
            config.keepalive_interval,
            Some(LivenessPolicy::DESKTOP.ssh_keepalive_interval)
        );
        assert_eq!(config.keepalive_max, 3);
        assert_eq!(config.inactivity_timeout, None);
    }

    #[test]
    fn the_host_key_types_known_hosts_holds_are_asked_for_first() {
        let p256 = Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        };
        let rsa = Algorithm::Rsa { hash: None };

        let known = |plain: Vec<Algorithm>| KnownTypes {
            plain,
            authority: false,
        };
        let ecdsa_known = russh_config(&LivenessPolicy::DESKTOP, &known(vec![p256.clone()]))
            .preferred
            .key;
        let rsa_known = russh_config(&LivenessPolicy::DESKTOP, &known(vec![rsa])).preferred.key;
        let unknown = russh_config(&LivenessPolicy::DESKTOP, &KnownTypes::default()).preferred;
        let vouched = russh_config(
            &LivenessPolicy::DESKTOP,
            &KnownTypes {
                plain: Vec::new(),
                authority: true,
            },
        )
        .preferred;

        assert_eq!(ecdsa_known.first(), Some(&p256));
        assert!(
            rsa_known
                .iter()
                .take_while(|algorithm| matches!(algorithm, Algorithm::Rsa { .. }))
                .count()
                >= 2
        );
        assert_eq!(unknown.key.as_ref(), Preferred::default().key.as_ref());
        assert_eq!(ecdsa_known.len(), unknown.key.len());
        assert!(
            unknown.host_key_certificates.is_empty(),
            "no authority, no certificate asked for"
        );
        assert_eq!(vouched.host_key_certificates.as_ref(), unknown.key.as_ref());
    }

    #[test]
    fn a_hop_without_a_user_logs_in_as_the_local_user_on_port_22() {
        let named = SshDestination::new("db.internal", Some(2222), Some("deploy".to_owned())).unwrap();
        let unnamed = SshDestination::new("jump1", None, None).unwrap();

        let named = Hop::new(&named).unwrap();
        assert_eq!((named.user.as_str(), named.port), ("deploy", 2222));
        if let Some(local) = local_user() {
            let unnamed = Hop::new(&unnamed).unwrap();
            assert_eq!((unnamed.user, unnamed.port), (local, 22));
        }
    }
}
