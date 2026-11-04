use std::path::Path;
use std::time::Duration;

use russh::keys::agent::client::{AgentClient, AgentStream};
use russh::keys::agent::{AgentIdentity, AgentSessionBinding};
use russh::keys::ssh_key::PublicKey;

use super::services::InProcessSsh;

// The bound OpenSSH's own ssh-add -l gets in the system transport (Linux ADR 0020).
const AGENT_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) type Agent = AgentClient<Box<dyn AgentStream + Send + Unpin>>;

// The user's agent for one hop. OpenSSH binds each agent connection to one session, which keys
// added with destination constraints need, so every hop opens its own.
pub(crate) struct AgentSlot {
    binding: Option<AgentSessionBinding>,
    state: State,
}

enum State {
    Untried,
    Ready {
        agent: Agent,
        identities: Vec<AgentIdentity>,
    },
    Unavailable {
        location: String,
    },
}

impl AgentSlot {
    pub fn new(binding: Option<AgentSessionBinding>) -> Self {
        Self {
            binding,
            state: State::Untried,
        }
    }

    pub async fn session(&mut self, services: &InProcessSsh) -> Option<(&mut Agent, &[AgentIdentity])> {
        if matches!(self.state, State::Untried) {
            self.state = connect(services, self.binding.as_ref()).await;
        }
        match &mut self.state {
            State::Ready { agent, identities } => Some((agent, identities.as_slice())),
            State::Untried | State::Unavailable { .. } => None,
        }
    }

    pub async fn holds(&mut self, services: &InProcessSsh, key: &PublicKey) -> bool {
        self.session(services)
            .await
            .is_some_and(|(_, identities)| identities.iter().any(|identity| signs_for(identity, key)))
    }

    pub fn unavailable(&self) -> Option<&str> {
        match &self.state {
            State::Unavailable { location } => Some(location),
            State::Untried | State::Ready { .. } => None,
        }
    }
}

// A certificate the agent holds signs with the key it certifies.
pub(crate) fn signs_for(identity: &AgentIdentity, key: &PublicKey) -> bool {
    match identity {
        AgentIdentity::PublicKey { key: held, .. } => held.key_data() == key.key_data(),
        AgentIdentity::Certificate { certificate, .. } => certificate.public_key() == key.key_data(),
    }
}

pub(crate) fn identity_algorithm(identity: &AgentIdentity) -> russh::keys::ssh_key::Algorithm {
    match identity {
        AgentIdentity::PublicKey { key, .. } => key.algorithm(),
        AgentIdentity::Certificate { certificate, .. } => certificate.public_key().algorithm(),
    }
}

async fn connect(services: &InProcessSsh, binding: Option<&AgentSessionBinding>) -> State {
    let location = services
        .agent
        .as_deref()
        .map_or_else(|| "SSH_AUTH_SOCK".to_owned(), |path| path.display().to_string());
    let attempt = async {
        let mut agent = open(services).await?;
        // An agent without the extension, as Pageant is, refuses it and lists every key anyway.
        if let Some(binding) = binding
            && let Err(error) = agent.bind_session(binding, false).await
        {
            tracing::debug!(%error, "the SSH agent did not bind to the session");
        }
        let identities = agent.request_identities().await.ok()?;
        Some(State::Ready { agent, identities })
    };
    match tokio::time::timeout(AGENT_TIMEOUT, attempt).await {
        Ok(Some(ready)) => ready,
        Ok(None) | Err(_) => {
            tracing::debug!(%location, "no SSH agent answered");
            State::Unavailable { location }
        }
    }
}

async fn open(services: &InProcessSsh) -> Option<Agent> {
    if let Some(path) = services.agent.as_deref() {
        match open_at(path).await {
            Ok(agent) => return Some(agent),
            Err(error) => tracing::debug!(%error, path = %path.display(), "the SSH agent could not be opened"),
        }
    }
    if services.pageant {
        return open_pageant().await;
    }
    None
}

#[cfg(unix)]
async fn open_at(path: &Path) -> Result<Agent, russh::keys::Error> {
    Ok(AgentClient::connect_uds(path).await?.dynamic())
}

// Any user can create the agent's pipe while the agent service is stopped, which is its default,
// so the pipe is used only when this user, LocalSystem or the Administrators own it.
#[cfg(windows)]
async fn open_at(path: &Path) -> Result<Agent, russh::keys::Error> {
    use std::os::windows::io::AsRawHandle;

    use tokio::net::windows::named_pipe::ClientOptions;

    const ERROR_PIPE_BUSY: i32 = 231;
    let pipe = loop {
        match ClientOptions::new().open(path) {
            Ok(pipe) => break pipe,
            Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) => {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(error) => return Err(error.into()),
        }
    };
    if !super::pipe_owner::owned_by_user_or_system(pipe.as_raw_handle())? {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "the SSH agent's pipe belongs to another user",
        )
        .into());
    }
    Ok(AgentClient::connect(pipe).dynamic())
}

#[cfg(windows)]
async fn open_pageant() -> Option<Agent> {
    match AgentClient::connect_pageant().await {
        Ok(agent) => Some(agent.dynamic()),
        Err(error) => {
            tracing::debug!(%error, "Pageant is not running");
            None
        }
    }
}

#[cfg(not(windows))]
async fn open_pageant() -> Option<Agent> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn services(agent: Option<&Path>) -> InProcessSsh {
        InProcessSsh {
            user_known_hosts: None,
            other_known_hosts: Vec::new(),
            identity_files: Vec::new(),
            agent: agent.map(Path::to_path_buf),
            pageant: false,
        }
    }

    #[tokio::test]
    async fn an_agent_that_is_not_there_is_named_where_it_was_looked_for() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("agent.sock");
        let mut slot = AgentSlot::new(None);

        assert!(slot.session(&services(Some(&missing))).await.is_none());
        assert_eq!(slot.unavailable(), Some(missing.display().to_string().as_str()));

        let mut unset = AgentSlot::new(None);
        assert!(unset.session(&services(None)).await.is_none());
        assert_eq!(unset.unavailable(), Some("SSH_AUTH_SOCK"));
    }
}
