use std::time::Duration;

#[derive(Debug)]
pub(super) enum HostKeyPromptEvent {
    WaitingForUser,
    UserResponded { declined_fingerprint: Option<String> },
}

pub(super) enum HandshakeWaitError<E> {
    Timeout,
    HostKeyDeclined(String),
    Handshake(E),
}

pub(super) async fn wait_for_handshake<F, T, E>(
    handshake: F,
    mut prompt_events: tokio::sync::mpsc::UnboundedReceiver<HostKeyPromptEvent>,
    timeout: Duration,
) -> Result<T, HandshakeWaitError<E>>
where
    F: std::future::Future<Output = Result<T, E>>,
{
    let mut handshake = std::pin::pin!(handshake);
    let mut deadline_at = tokio::time::Instant::now() + timeout;
    let deadline = tokio::time::sleep_until(deadline_at);
    tokio::pin!(deadline);
    let mut waiting_for_user = false;
    let mut remaining = timeout;

    loop {
        tokio::select! {
            biased;
            Some(event) = prompt_events.recv() => match event {
                HostKeyPromptEvent::WaitingForUser if !waiting_for_user => {
                    remaining = deadline_at.saturating_duration_since(tokio::time::Instant::now());
                    waiting_for_user = true;
                }
                HostKeyPromptEvent::UserResponded { declined_fingerprint } => {
                    if waiting_for_user {
                        waiting_for_user = false;
                        if let Some(fingerprint) = declined_fingerprint {
                            tracing::warn!(%fingerprint, "SSH host key declined; ending handshake");
                            return Err(HandshakeWaitError::HostKeyDeclined(fingerprint));
                        }
                        deadline_at = tokio::time::Instant::now() + remaining;
                        deadline.as_mut().reset(deadline_at);
                    }
                }
                HostKeyPromptEvent::WaitingForUser => {}
            },
            result = &mut handshake => return result.map_err(HandshakeWaitError::Handshake),
            _ = &mut deadline, if !waiting_for_user => return Err(HandshakeWaitError::Timeout),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn declining_a_prompt_ends_a_pending_ssh_handshake_immediately() {
        let (events, receiver) = tokio::sync::mpsc::unbounded_channel();
        let handshake = async move {
            events.send(HostKeyPromptEvent::WaitingForUser).unwrap();
            events
                .send(HostKeyPromptEvent::UserResponded {
                    declined_fingerprint: Some("SHA256:declined".to_owned()),
                })
                .unwrap();
            std::future::pending::<Result<(), ()>>().await
        };

        assert!(matches!(
            wait_for_handshake(handshake, receiver, Duration::from_secs(10)).await,
            Err(HandshakeWaitError::HostKeyDeclined(fingerprint)) if fingerprint == "SHA256:declined"
        ));
    }
}
