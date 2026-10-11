use std::net::{Ipv4Addr, SocketAddr, TcpListener};
use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::argv::ControlOp;
use super::error::spawn_failure;
use super::stderr_classify::{ClassifyContext, classify};
use super::supervisor::{ForwardCancel, run_control};
use super::{ForwardTarget, LocalEndpoint, OpenSshError, OpenSshSession, TimeoutPhase};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ForwardRoute {
    #[default]
    UnixSocket,
    NamedUnixSocket(String),
    LoopbackTcp,
}

#[derive(Debug)]
pub struct OpenSshForward {
    session: Arc<OpenSshSession>,
    target: ForwardTarget,
    local: LocalEndpoint,
}

impl OpenSshForward {
    pub fn local_endpoint(&self) -> &LocalEndpoint {
        &self.local
    }

    pub fn target(&self) -> &ForwardTarget {
        &self.target
    }

    pub fn session(&self) -> &Arc<OpenSshSession> {
        &self.session
    }
}

impl OpenSshSession {
    pub async fn forward(
        self: &Arc<Self>,
        target: ForwardTarget,
        route: ForwardRoute,
    ) -> Result<OpenSshForward, OpenSshError> {
        if self.is_closed() {
            return Err(self.master_exited());
        }
        let local = self.local_endpoint(route)?;
        let request = run_control(
            &self.ssh_program,
            &self.control,
            ControlOp::Forward {
                listen: &local,
                target: &target,
            },
        );
        let output = tokio::time::timeout(self.timeouts.channel_open, request)
            .await
            .map_err(|_| OpenSshError::Timeout {
                phase: TimeoutPhase::ChannelOpen,
            })?
            .map_err(|error| spawn_failure(&self.ssh_program, &error))?;
        if !output.status.success() {
            let target_text = target.to_string();
            let context = ClassifyContext {
                host: &self.host,
                forward_target: Some(&target_text),
                declined_host_key: None,
            };
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(classify(output.status.code(), &stderr, &context));
        }
        Ok(OpenSshForward {
            session: self.clone(),
            target,
            local,
        })
    }

    fn local_endpoint(&self, route: ForwardRoute) -> Result<LocalEndpoint, OpenSshError> {
        match route {
            ForwardRoute::UnixSocket => {
                let index = self.next_forward.fetch_add(1, Ordering::Relaxed);
                Ok(LocalEndpoint::Unix(self.master_dir.join(format!("f{index}"))))
            }
            ForwardRoute::NamedUnixSocket(name) => self.named_socket(&name),
            ForwardRoute::LoopbackTcp => free_loopback_port().map(LocalEndpoint::Tcp),
        }
    }

    fn named_socket(&self, name: &str) -> Result<LocalEndpoint, OpenSshError> {
        if name.is_empty() || name.contains('/') || name == "." || name == ".." {
            return Err(OpenSshError::LocalBind {
                detail: "a forwarded socket name must be a single path component".into(),
            });
        }
        let index = self.next_forward.fetch_add(1, Ordering::Relaxed);
        let directory = self.master_dir.join(format!("f{index}"));
        std::os::unix::fs::DirBuilderExt::mode(&mut std::fs::DirBuilder::new(), 0o700)
            .create(&directory)
            .map_err(|error| OpenSshError::LocalBind {
                detail: error.to_string(),
            })?;
        Ok(LocalEndpoint::Unix(directory.join(name)))
    }
}

// `ssh -O forward` does not report the port OpenSSH picks for a local
// forward requested on port 0, so a free port is chosen here first.
// ExitOnForwardFailure turns a lost race for that port into a failed request.
fn free_loopback_port() -> Result<SocketAddr, OpenSshError> {
    let probe = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    TcpListener::bind(probe)
        .and_then(|listener| listener.local_addr())
        .map_err(|error| OpenSshError::LocalBind {
            detail: error.to_string(),
        })
}

impl Drop for OpenSshForward {
    fn drop(&mut self) {
        let request = ForwardCancel {
            listen: self.local.clone(),
            target: self.target.clone(),
        };
        if self.session.forwards.send(request).is_err() {
            tracing::debug!("the ssh supervisor has stopped; the forward ends with the master");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_free_loopback_port_is_on_loopback_and_not_zero() {
        let address = free_loopback_port().unwrap();
        assert!(address.ip().is_loopback());
        assert_ne!(address.port(), 0);
    }
}
