use std::io;

use futures::StreamExt;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{CredentialInteraction, PromptReason, PromptReply};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio_util::bytes::BytesMut;
use tokio_util::codec::{Framed, LengthDelimitedCodec};
use zeroize::Zeroizing;

use crate::SshAuth;
use crate::prompt::AskpassPrompt;
use crate::stderr_classify::DeclinedHostKey;

const MAX_FRAME: usize = 65_536;
const ANSWER: u8 = 0x00;
const CANCEL: u8 = 0x01;

enum Reply {
    Answer(Zeroizing<String>),
    Cancel,
}

pub(crate) struct AskpassBridge {
    owner_uid: u32,
    target: String,
    interaction: CredentialInteraction,
    password: Option<SecretString>,
    /// The `user@host` whose password prompt the stored password answers.
    password_owner: Option<String>,
    passphrase: Option<SecretString>,
    used_password: bool,
    used_passphrase: bool,
    declined_host_key: Option<DeclinedHostKey>,
}

impl AskpassBridge {
    pub fn new(
        owner_uid: u32,
        target: String,
        interaction: CredentialInteraction,
        auth: &SshAuth,
        password_owner: Option<String>,
    ) -> Self {
        let (password, passphrase) = match auth {
            SshAuth::Password { password } => (Some(password.clone()), None),
            SshAuth::PrivateKey { passphrase, .. } => (None, passphrase.clone()),
            SshAuth::Agent | SshAuth::KeyboardInteractive => (None, None),
        };
        Self {
            owner_uid,
            target,
            interaction,
            password,
            password_owner,
            passphrase,
            used_password: false,
            used_passphrase: false,
            declined_host_key: None,
        }
    }

    fn owns_password(&self, user_host: &str) -> bool {
        self.password_owner
            .as_deref()
            .is_some_and(|owner| owner.eq_ignore_ascii_case(user_host))
    }

    pub fn declined_host_key(&self) -> Option<&DeclinedHostKey> {
        self.declined_host_key.as_ref()
    }

    pub async fn handle(&mut self, stream: UnixStream) -> io::Result<()> {
        if stream.peer_cred()?.uid() != self.owner_uid {
            tracing::warn!("ignored an askpass connection from another user");
            return Ok(());
        }
        let mut framed = Framed::new(stream, codec());
        let hint = next_frame(&mut framed).await?;
        let text = next_frame(&mut framed).await?;
        let prompt = AskpassPrompt::classify(&String::from_utf8_lossy(&hint), &String::from_utf8_lossy(&text));
        let reply = self.reply_to(&prompt).await;
        // The reply goes out through a buffer this side wipes, rather
        // than the codec's, which would keep a copy of the secret.
        let mut stream = framed.into_inner();
        stream.write_all(&encode(reply)).await
    }

    async fn reply_to(&mut self, prompt: &AskpassPrompt) -> Reply {
        if let AskpassPrompt::Notification { text } = prompt {
            tracing::info!(notification = %text, "ssh notification");
            return Reply::Answer(Zeroizing::new(String::new()));
        }
        // A jump host asks first, through the same askpass, and must not be
        // handed the destination's password.
        if let AskpassPrompt::Password { user_host } = prompt
            && self.owns_password(user_host)
            && let Some(secret) = self.password.take()
        {
            self.used_password = true;
            return answer(&secret);
        }
        if matches!(prompt, AskpassPrompt::Passphrase { .. })
            && let Some(secret) = self.passphrase.take()
        {
            self.used_passphrase = true;
            return answer(&secret);
        }

        let CredentialInteraction::Attended(prompter) = &self.interaction else {
            self.record_declined(prompt);
            return Reply::Cancel;
        };
        let reason = match prompt {
            AskpassPrompt::Password { user_host } if self.used_password && self.owns_password(user_host) => {
                PromptReason::Rejected
            }
            AskpassPrompt::Passphrase { .. } if self.used_passphrase => PromptReason::Rejected,
            _ => PromptReason::NotStored,
        };
        let Some(request) = prompt.credential_prompt(&self.target, reason) else {
            return Reply::Answer(Zeroizing::new(String::new()));
        };
        match prompter.prompt(request).await {
            PromptReply::Submitted { values, .. } => match prompt {
                AskpassPrompt::HostKeyConfirmation { .. } | AskpassPrompt::Confirmation { .. } => {
                    Reply::Answer(Zeroizing::new("yes".to_owned()))
                }
                _ => values.first().map_or(Reply::Cancel, answer),
            },
            PromptReply::Cancelled => {
                self.record_declined(prompt);
                Reply::Cancel
            }
        }
    }

    fn record_declined(&mut self, prompt: &AskpassPrompt) {
        if let AskpassPrompt::HostKeyConfirmation {
            algorithm, fingerprint, ..
        } = prompt
        {
            self.declined_host_key = Some(DeclinedHostKey {
                algorithm: algorithm.clone(),
                fingerprint: fingerprint.clone(),
            });
        }
    }
}

pub(crate) fn codec() -> LengthDelimitedCodec {
    LengthDelimitedCodec::builder()
        .big_endian()
        .length_field_type::<u32>()
        .max_frame_length(MAX_FRAME)
        .new_codec()
}

async fn next_frame(framed: &mut Framed<UnixStream, LengthDelimitedCodec>) -> io::Result<BytesMut> {
    framed.next().await.unwrap_or_else(|| {
        Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "the askpass helper closed the connection",
        ))
    })
}

fn answer(secret: &SecretString) -> Reply {
    Reply::Answer(Zeroizing::new(secret.expose_secret().to_owned()))
}

/// One length-prefixed frame. The capacity is exact, so the vector
/// never reallocates and leaves an unwiped copy behind.
fn encode(reply: Reply) -> Zeroizing<Vec<u8>> {
    let (tag, text) = match &reply {
        Reply::Answer(text) => (ANSWER, text.as_bytes()),
        Reply::Cancel => (CANCEL, &[][..]),
    };
    let length = 1 + text.len();
    let mut frame = Zeroizing::new(Vec::with_capacity(4 + length));
    frame.extend_from_slice(&u32::try_from(length).unwrap_or(u32::MAX).to_be_bytes());
    frame.push(tag);
    frame.extend_from_slice(text);
    frame
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::MetadataExt;
    use std::sync::Arc;

    use futures::SinkExt;
    use tablepro_core::credentials::PromptPurpose;
    use tablepro_test_support::FakePrompter;
    use tokio_util::bytes::Bytes;

    use super::*;

    const HOST_KEY_PROMPT: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is: SHA256:abc\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

    /// The same prompt as OpenSSH 9.6 writes it, which is what Ubuntu
    /// 24.04 and the CI runner have: no colon, and a closing period.
    const HOST_KEY_PROMPT_9_6: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

    fn current_uid() -> u32 {
        tempfile::tempdir().unwrap().path().metadata().unwrap().uid()
    }

    fn bridge(interaction: CredentialInteraction, auth: &SshAuth) -> AskpassBridge {
        AskpassBridge::new(
            current_uid(),
            "deploy@bastion".to_owned(),
            interaction,
            auth,
            Some("deploy@bastion".to_owned()),
        )
    }

    async fn exchange(bridge: &mut AskpassBridge, hint: &str, text: &str) -> Vec<u8> {
        let (client, server) = UnixStream::pair().unwrap();
        let mut client = Framed::new(client, codec());
        let talk = async {
            client.send(Bytes::copy_from_slice(hint.as_bytes())).await.unwrap();
            client.send(Bytes::copy_from_slice(text.as_bytes())).await.unwrap();
            client.next().await.unwrap().unwrap()
        };
        let (served, reply) = tokio::join!(bridge.handle(server), talk);
        served.unwrap();
        reply.to_vec()
    }

    #[tokio::test]
    async fn bridge_unattended_cancels() {
        let mut bridge = bridge(CredentialInteraction::Unattended, &SshAuth::Agent);
        assert_eq!(exchange(&mut bridge, "", "deploy@bastion's password: ").await, [CANCEL]);
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT).await, [CANCEL]);
        assert_eq!(
            bridge.declined_host_key().map(|key| key.fingerprint.as_str()),
            Some("SHA256:abc")
        );
    }

    #[tokio::test]
    async fn bridge_uses_supplied_password_once_then_prompts() {
        let prompter = Arc::new(FakePrompter::new([PromptReply::Submitted {
            values: vec![SecretString::from("typed")],
            remember: false,
        }]));
        let auth = SshAuth::Password {
            password: SecretString::from("s3cret"),
        };
        let mut bridge = bridge(CredentialInteraction::Attended(prompter.clone()), &auth);

        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00s3cret"
        );
        assert!(prompter.requests().is_empty());

        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00typed"
        );
        let requests = prompter.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::SshPassword {
                reason: PromptReason::Rejected
            }
        );
    }

    #[tokio::test]
    async fn a_jump_host_is_never_given_the_destination_password() {
        let prompter = Arc::new(FakePrompter::new([PromptReply::Submitted {
            values: vec![SecretString::from("jump-typed")],
            remember: false,
        }]));
        let auth = SshAuth::Password {
            password: SecretString::from("s3cret"),
        };
        let mut bridge = bridge(CredentialInteraction::Attended(prompter.clone()), &auth);

        assert_eq!(
            exchange(&mut bridge, "", "ops@jump1's password: ").await,
            b"\x00jump-typed"
        );
        let requests = prompter.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].target, "ops@jump1");
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::SshPassword {
                reason: PromptReason::NotStored
            }
        );
        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00s3cret"
        );
    }

    #[tokio::test]
    async fn without_a_resolved_owner_the_stored_password_is_not_sent() {
        let auth = SshAuth::Password {
            password: SecretString::from("s3cret"),
        };
        let mut bridge = AskpassBridge::new(
            current_uid(),
            "bastion".to_owned(),
            CredentialInteraction::Unattended,
            &auth,
            None,
        );

        assert_eq!(exchange(&mut bridge, "", "deploy@bastion's password: ").await, [CANCEL]);
    }

    /// The bridge has to answer the older wording too, or ssh gets no
    /// answer and reports the host key as unverified.
    #[tokio::test]
    async fn an_older_openssh_host_key_prompt_is_answered_the_same_way() {
        let accepting = Arc::new(FakePrompter::new([PromptReply::Submitted {
            values: Vec::new(),
            remember: false,
        }]));
        let mut bridge = bridge(CredentialInteraction::Attended(accepting), &SshAuth::Agent);

        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT_9_6).await, b"\x00yes");
        assert!(bridge.declined_host_key().is_none());
    }

    #[tokio::test]
    async fn host_key_confirmation_submitted_answers_yes() {
        let accepting = Arc::new(FakePrompter::new([PromptReply::Submitted {
            values: Vec::new(),
            remember: false,
        }]));
        let mut bridge = bridge(CredentialInteraction::Attended(accepting), &SshAuth::Agent);
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT).await, b"\x00yes");
        assert!(bridge.declined_host_key().is_none());

        let declining = Arc::new(FakePrompter::new([PromptReply::Cancelled]));
        let mut bridge = self::bridge(CredentialInteraction::Attended(declining), &SshAuth::Agent);
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT).await, [CANCEL]);
        assert_eq!(
            bridge.declined_host_key().map(|key| key.algorithm.as_str()),
            Some("ED25519")
        );
    }

    #[tokio::test]
    async fn oversized_frame_is_rejected() {
        let mut bridge = bridge(CredentialInteraction::Unattended, &SshAuth::Agent);
        let (mut client, server) = UnixStream::pair().unwrap();
        let oversized = u32::try_from(MAX_FRAME + 1).unwrap().to_be_bytes();
        client.write_all(&oversized).await.unwrap();
        let error = bridge.handle(server).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn connection_from_another_uid_gets_no_reply() {
        let mut bridge = AskpassBridge::new(
            current_uid().wrapping_add(1),
            "bastion".to_owned(),
            CredentialInteraction::Unattended,
            &SshAuth::Agent,
            None,
        );
        let (client, server) = UnixStream::pair().unwrap();
        bridge.handle(server).await.unwrap();
        let mut client = Framed::new(client, codec());
        assert!(client.next().await.is_none());
    }
}
