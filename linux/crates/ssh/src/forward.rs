use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, NetworkEndpoint, SshFailure, TimeoutPhase, Transport, TransportError, TransportKind,
    TransportRoute, TransportStream,
};
use tokio::net::UnixStream;

use crate::argv::ControlOp;
use crate::known_hosts::spawn_failure;
use crate::lock;
use crate::session::SshSession;
use crate::stderr_classify::{ClassifyContext, classify};
use crate::supervisor::{ForwardCancel, run_control};

#[derive(Debug)]
pub struct SshForwardTransport {
    session: Arc<SshSession>,
    service: NetworkEndpoint,
    socket: PathBuf,
    liveness: LivenessPolicy,
}

impl SshSession {
    pub async fn forward(
        self: &Arc<Self>,
        target: NetworkEndpoint,
        liveness: &LivenessPolicy,
    ) -> Result<Arc<dyn Transport>, TransportError> {
        if self.is_closed() {
            return Err(self.master_exited());
        }
        let index = self.next_forward.fetch_add(1, Ordering::Relaxed);
        let socket = self.master_dir.join(format!("f{index}"));
        let request = run_control(
            &self.ssh_program,
            &self.control,
            ControlOp::Forward {
                listen: &socket,
                target: &target,
            },
        );
        let output = match tokio::time::timeout(liveness.ssh_channel_open_timeout, request).await {
            Err(_) => {
                return Err(TransportError::Timeout {
                    phase: TimeoutPhase::SshChannelOpen,
                });
            }
            Ok(Err(error)) => return Err(spawn_failure(&self.ssh_program, &error).into()),
            Ok(Ok(output)) => output,
        };
        if !output.status.success() {
            let target_text = target.to_string();
            let context = ClassifyContext {
                host: &self.host,
                forward_target: Some(&target_text),
                declined_host_key: None,
            };
            return Err(classify(
                output.status.code(),
                &String::from_utf8_lossy(&output.stderr),
                &context,
            ));
        }
        Ok(Arc::new(SshForwardTransport {
            session: self.clone(),
            service: target,
            socket,
            liveness: *liveness,
        }))
    }

    pub(crate) fn master_exited(&self) -> TransportError {
        let status = *lock(&self.exit_status);
        let detail = lock(&self.stderr_tail)
            .lines()
            .last()
            .unwrap_or("the ssh master exited")
            .to_owned();
        SshFailure::MasterExited { status, detail }.into()
    }
}

#[async_trait]
impl Transport for SshForwardTransport {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        &self.service
    }

    fn kind(&self) -> TransportKind {
        TransportKind::SshForward {
            destination: self.session.destination.clone(),
        }
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::UnixSocket(self.socket.clone())
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        if self.session.is_closed() {
            return Err(self.session.master_exited());
        }
        match tokio::time::timeout(self.liveness.connect_timeout, UnixStream::connect(&self.socket)).await {
            Err(_) => Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect,
            }),
            Ok(Ok(stream)) => Ok(Box::new(stream)),
            Ok(Err(error)) if self.session.is_closed() => {
                tracing::debug!(%error, "the forward socket closed with the ssh master");
                Err(self.session.master_exited())
            }
            Ok(Err(error)) => Err(SshFailure::ChannelOpenFailed {
                target: self.service.to_string(),
                detail: error.to_string(),
            }
            .into()),
        }
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.session.forward(endpoint, &self.liveness).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        if self.session.is_closed() {
            return Some(self.session.master_exited());
        }
        let tail = lock(&self.session.stderr_tail).clone();
        tail.lines()
            .rev()
            .find(|line| line.contains(": open failed"))
            .map(|line| {
                SshFailure::ChannelOpenFailed {
                    target: self.service.to_string(),
                    detail: line.to_owned(),
                }
                .into()
            })
    }
}

impl Drop for SshForwardTransport {
    fn drop(&mut self) {
        let request = ForwardCancel {
            listen: self.socket.clone(),
            target: self.service.clone(),
        };
        if self.session.forwards.send(request).is_err() {
            tracing::debug!("the ssh supervisor has stopped; the forward ends with the master");
        }
    }
}
