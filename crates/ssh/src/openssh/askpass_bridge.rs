use std::io;
use std::sync::Arc;
use std::time::Duration;

use secrecy::{ExposeSecret, SecretString};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use zeroize::Zeroizing;

use super::stderr_classify::DeclinedHostKey;
use super::{AskpassPrompt, OpenSshAuth, OpenSshConfig, PromptAnswer, Prompter};

pub(crate) const MAX_FRAME: usize = 65_536;
const FRAME_READ_TIMEOUT: Duration = Duration::from_secs(5);
const ANSWER: u8 = 0x00;
const CANCEL: u8 = 0x01;

pub(crate) struct AskpassBridge {
    owner_uid: u32,
    account: Option<(String, String)>,
    password: Option<SecretString>,
    key_path: Option<String>,
    passphrase: Option<SecretString>,
    prompter: Arc<dyn Prompter>,
    declined_host_key: Option<DeclinedHostKey>,
}

impl AskpassBridge {
    pub fn new(owner_uid: u32, config: &OpenSshConfig, prompter: Arc<dyn Prompter>) -> Self {
        let account = config
            .destination
            .user()
            .map(|user| (user.to_owned(), config.destination.host().to_owned()));
        let (password, key_path, passphrase) = match &config.auth {
            OpenSshAuth::Password { password } => (Some(password.clone()), None, None),
            OpenSshAuth::PrivateKey { path, passphrase } => (
                None,
                path.as_ref().map(|path| path.to_string_lossy().into_owned()),
                passphrase.clone(),
            ),
            OpenSshAuth::Agent => (None, None, None),
        };
        Self {
            owner_uid,
            account,
            password,
            key_path,
            passphrase,
            prompter,
            declined_host_key: None,
        }
    }

    pub fn declined_host_key(&self) -> Option<&DeclinedHostKey> {
        self.declined_host_key.as_ref()
    }

    pub async fn handle(&mut self, mut stream: UnixStream) -> io::Result<()> {
        if stream.peer_cred()?.uid() != self.owner_uid {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "the askpass peer belongs to another user",
            ));
        }
        let (hint, text) = tokio::time::timeout(FRAME_READ_TIMEOUT, read_request(&mut stream))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "the askpass helper sent no prompt"))??;
        let prompt = AskpassPrompt::classify(&String::from_utf8_lossy(&hint), &String::from_utf8_lossy(&text));
        let reply = self.reply_to(&prompt).await;
        stream.write_all(&reply).await?;
        stream.flush().await
    }

    async fn reply_to(&mut self, prompt: &AskpassPrompt) -> Zeroizing<Vec<u8>> {
        if let Some(stored) = self.stored_answer(prompt) {
            return stored;
        }
        if let AskpassPrompt::Notification { text } = prompt {
            self.prompter.notify(text);
            return answer_frame(b"");
        }
        match (prompt.is_confirmation(), self.prompter.answer(prompt).await) {
            (true, PromptAnswer::Accept) => answer_frame(b"yes"),
            (false, PromptAnswer::Secret(secret)) => answer_frame(secret.expose_secret().as_bytes()),
            _ => {
                self.record_declined(prompt);
                cancel_frame()
            }
        }
    }

    fn stored_answer(&mut self, prompt: &AskpassPrompt) -> Option<Zeroizing<Vec<u8>>> {
        let secret = match prompt {
            AskpassPrompt::Password { user_host } if self.is_configured_account(user_host) => self.password.take(),
            AskpassPrompt::Passphrase { key_path } if self.key_path.as_deref() == Some(key_path.as_str()) => {
                self.passphrase.take()
            }
            _ => None,
        }?;
        Some(answer_frame(secret.expose_secret().as_bytes()))
    }

    fn is_configured_account(&self, user_host: &str) -> bool {
        let Some((user, host)) = &self.account else {
            return false;
        };
        user_host
            .rsplit_once('@')
            .is_some_and(|(prompt_user, prompt_host)| prompt_user == user && prompt_host.eq_ignore_ascii_case(host))
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

async fn read_request(stream: &mut UnixStream) -> io::Result<(Vec<u8>, Vec<u8>)> {
    let hint = read_frame(stream).await?;
    let text = read_frame(stream).await?;
    Ok((hint, text))
}

async fn read_frame(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let length = usize::try_from(stream.read_u32().await?).map_err(io::Error::other)?;
    if length > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the askpass frame is too large",
        ));
    }
    let mut frame = vec![0u8; length];
    stream.read_exact(&mut frame).await?;
    Ok(frame)
}

fn answer_frame(answer: &[u8]) -> Zeroizing<Vec<u8>> {
    let length = u32::try_from(answer.len() + 1).unwrap_or(u32::MAX);
    let mut frame = Zeroizing::new(Vec::with_capacity(answer.len() + 5));
    frame.extend_from_slice(&length.to_be_bytes());
    frame.push(ANSWER);
    frame.extend_from_slice(answer);
    frame
}

fn cancel_frame() -> Zeroizing<Vec<u8>> {
    let mut frame = Zeroizing::new(1u32.to_be_bytes().to_vec());
    frame.push(CANCEL);
    frame
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::MetadataExt;
    use std::path::PathBuf;
    use std::sync::Mutex;

    use async_trait::async_trait;

    use super::*;
    use crate::openssh::{SshDestination, UnattendedPrompter};

    const HOST_KEY_PROMPT: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is: SHA256:abc\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";
    const HOST_KEY_PROMPT_9_6: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

    #[derive(Default)]
    struct ScriptedPrompter {
        answers: Mutex<Vec<PromptAnswer>>,
        asked: Mutex<Vec<AskpassPrompt>>,
    }

    impl ScriptedPrompter {
        fn new(mut answers: Vec<PromptAnswer>) -> Arc<Self> {
            answers.reverse();
            Arc::new(Self {
                answers: Mutex::new(answers),
                asked: Mutex::new(Vec::new()),
            })
        }

        fn asked(&self) -> Vec<AskpassPrompt> {
            self.asked.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl Prompter for ScriptedPrompter {
        async fn answer(&self, prompt: &AskpassPrompt) -> PromptAnswer {
            self.asked.lock().unwrap().push(prompt.clone());
            self.answers.lock().unwrap().pop().unwrap_or(PromptAnswer::Decline)
        }
    }

    fn current_uid() -> u32 {
        tempfile::tempdir().unwrap().path().metadata().unwrap().uid()
    }

    fn config(auth: OpenSshAuth) -> OpenSshConfig {
        OpenSshConfig {
            destination: SshDestination::new("bastion", Some(2222), Some("deploy".to_owned())).unwrap(),
            jump_hosts: SshDestination::parse_jump_list("ops@jump1").unwrap(),
            auth,
        }
    }

    fn password_auth() -> OpenSshAuth {
        OpenSshAuth::Password {
            password: SecretString::from("s3cret"),
        }
    }

    fn bridge(auth: OpenSshAuth, prompter: Arc<dyn Prompter>) -> AskpassBridge {
        AskpassBridge::new(current_uid(), &config(auth), prompter)
    }

    async fn send_frame(stream: &mut UnixStream, bytes: &[u8]) {
        stream.write_u32(u32::try_from(bytes.len()).unwrap()).await.unwrap();
        stream.write_all(bytes).await.unwrap();
    }

    async fn exchange(bridge: &mut AskpassBridge, hint: &str, text: &str) -> Vec<u8> {
        let (mut client, server) = UnixStream::pair().unwrap();
        let talk = async {
            send_frame(&mut client, hint.as_bytes()).await;
            send_frame(&mut client, text.as_bytes()).await;
            let length = client.read_u32().await.unwrap();
            let mut reply = vec![0u8; length as usize];
            client.read_exact(&mut reply).await.unwrap();
            reply
        };
        let (served, reply) = tokio::join!(bridge.handle(server), talk);
        served.unwrap();
        reply
    }

    #[tokio::test]
    async fn the_stored_password_answers_only_the_configured_account() {
        let prompter = ScriptedPrompter::new(Vec::new());
        let mut bridge = bridge(password_auth(), prompter.clone());
        assert_eq!(
            exchange(&mut bridge, "", "deploy@BASTION's password: ").await,
            b"\x00s3cret"
        );
        assert!(prompter.asked().is_empty());
    }

    #[tokio::test]
    async fn the_stored_password_is_never_sent_to_a_jump_host_prompt() {
        let prompter = ScriptedPrompter::new(vec![PromptAnswer::Decline]);
        let mut bridge = bridge(password_auth(), prompter.clone());
        for prompt in [
            "ops@jump1's password: ",
            "deploy@jump1's password: ",
            "root@bastion's password: ",
            "(ops@jump1) deploy@bastion's password: ",
        ] {
            assert_eq!(exchange(&mut bridge, "", prompt).await, [CANCEL], "{prompt}");
        }
        assert_eq!(prompter.asked().len(), 4);
        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00s3cret"
        );
    }

    #[tokio::test]
    async fn a_destination_without_a_user_never_answers_from_the_store() {
        let prompter = ScriptedPrompter::new(Vec::new());
        let mut config = config(password_auth());
        config.destination = SshDestination::new("bastion", None, None).unwrap();
        let mut bridge = AskpassBridge::new(current_uid(), &config, prompter.clone());
        assert_eq!(exchange(&mut bridge, "", "deploy@bastion's password: ").await, [CANCEL]);
        assert_eq!(prompter.asked().len(), 1);
    }

    #[tokio::test]
    async fn the_stored_password_is_used_once_then_the_prompter_is_asked() {
        let prompter = ScriptedPrompter::new(vec![PromptAnswer::Secret(SecretString::from("typed"))]);
        let mut bridge = bridge(password_auth(), prompter.clone());
        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00s3cret"
        );
        assert_eq!(
            exchange(&mut bridge, "", "deploy@bastion's password: ").await,
            b"\x00typed"
        );
        assert_eq!(prompter.asked().len(), 1);
    }

    #[tokio::test]
    async fn the_stored_passphrase_answers_only_the_configured_key() {
        let auth = OpenSshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/deploy/.ssh/id_ed25519")),
            passphrase: Some(SecretString::from("phrase")),
        };
        let prompter = ScriptedPrompter::new(Vec::new());
        let mut bridge = bridge(auth, prompter.clone());
        let other = "Enter passphrase for key '/home/deploy/.ssh/id_rsa': ";
        assert_eq!(exchange(&mut bridge, "", other).await, [CANCEL]);
        let configured = "Enter passphrase for key '/home/deploy/.ssh/id_ed25519': ";
        assert_eq!(exchange(&mut bridge, "", configured).await, b"\x00phrase");
        assert_eq!(prompter.asked().len(), 1);
    }

    #[tokio::test]
    async fn unattended_declines_host_keys_and_records_the_declined_key() {
        let mut bridge = bridge(password_auth(), Arc::new(UnattendedPrompter));
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT).await, [CANCEL]);
        assert_eq!(
            bridge.declined_host_key().map(|key| key.fingerprint.as_str()),
            Some("SHA256:abc")
        );
        assert_eq!(exchange(&mut bridge, "", "ops@jump1's password: ").await, [CANCEL]);
    }

    #[tokio::test]
    async fn host_key_prompts_always_reach_the_prompter_and_need_an_explicit_accept() {
        let prompter = ScriptedPrompter::new(vec![
            PromptAnswer::Accept,
            PromptAnswer::Secret(SecretString::from("yes")),
        ]);
        let mut bridge = bridge(password_auth(), prompter.clone());
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT_9_6).await, b"\x00yes");
        assert!(bridge.declined_host_key().is_none());
        assert_eq!(exchange(&mut bridge, "", HOST_KEY_PROMPT).await, [CANCEL]);
        assert_eq!(
            bridge.declined_host_key().map(|key| key.algorithm.as_str()),
            Some("ED25519")
        );
        assert_eq!(prompter.asked().len(), 2);
    }

    #[tokio::test]
    async fn a_secret_prompt_answered_with_accept_is_cancelled() {
        let prompter = ScriptedPrompter::new(vec![PromptAnswer::Accept]);
        let mut bridge = bridge(OpenSshAuth::Agent, prompter);
        assert_eq!(exchange(&mut bridge, "", "PIN: ").await, [CANCEL]);
    }

    #[tokio::test]
    async fn a_notification_is_answered_without_asking() {
        let prompter = ScriptedPrompter::new(Vec::new());
        let mut bridge = bridge(OpenSshAuth::Agent, prompter.clone());
        assert_eq!(exchange(&mut bridge, "none", "Confirm user presence").await, [ANSWER]);
        assert!(prompter.asked().is_empty());
    }

    #[tokio::test]
    async fn an_oversized_frame_is_rejected() {
        let mut bridge = bridge(password_auth(), Arc::new(UnattendedPrompter));
        let (mut client, server) = UnixStream::pair().unwrap();
        client.write_u32(u32::try_from(MAX_FRAME + 1).unwrap()).await.unwrap();
        let error = bridge.handle(server).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn a_peer_from_another_uid_is_rejected_without_a_reply() {
        let prompter = ScriptedPrompter::new(Vec::new());
        let mut bridge = AskpassBridge::new(
            current_uid().wrapping_add(1),
            &config(password_auth()),
            prompter.clone(),
        );
        let (mut client, server) = UnixStream::pair().unwrap();
        send_frame(&mut client, b"").await;
        send_frame(&mut client, b"deploy@bastion's password: ").await;
        let error = bridge.handle(server).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        let mut rest = Vec::new();
        let read = client.read_to_end(&mut rest).await;
        assert!(read.is_ok() || read.is_err_and(|error| error.kind() == io::ErrorKind::ConnectionReset));
        assert!(rest.is_empty());
        assert!(prompter.asked().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_peer_times_out() {
        let mut bridge = bridge(password_auth(), Arc::new(UnattendedPrompter));
        let (_client, server) = UnixStream::pair().unwrap();
        let error = bridge.handle(server).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }
}
