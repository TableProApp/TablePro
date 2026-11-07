use std::time::Duration;

use oo7::ashpd;
use tokio::io::AsyncReadExt;
use tokio::net::UnixStream;
use zeroize::Zeroizing;

// xdg-desktop-portal waits on its backend with no limit, since the backend may be showing an unlock
// prompt. This only ends a request whose backend never answers; nobody types a password this long.
const ANSWER_LIMIT: Duration = Duration::from_secs(300);
// The backend writes the secret before it answers, so the read only drains a local socket. The limit
// is the one oo7 puts on every Secret Service call.
const READ_LIMIT: Duration = Duration::from_secs(30);

// ashpd's own secret::retrieve reads the socket without checking the Response, so a refused request
// leaves it waiting on a socket GNOME Keyring never closes.
pub(super) async fn retrieve_secret() -> Result<oo7::Secret, ashpd::Error> {
    let (reader, writer) = UnixStream::pair()?;
    let answer = tokio::time::timeout(ANSWER_LIMIT, async {
        let portal = ashpd::desktop::secret::Secret::new().await?;
        portal.retrieve(&writer, Default::default()).await?.response()
    })
    .await
    .unwrap_or_else(|_| Err(timed_out("the Secret portal did not answer")));
    drop(writer);
    read_secret(answer, reader).await
}

async fn read_secret(answer: Result<(), ashpd::Error>, mut reader: UnixStream) -> Result<oo7::Secret, ashpd::Error> {
    answer?;
    let mut secret = Zeroizing::new(Vec::with_capacity(256));
    tokio::time::timeout(READ_LIMIT, reader.read_to_end(&mut secret))
        .await
        .map_err(|_| timed_out("the Secret portal did not close the secret's socket"))??;
    Ok(oo7::Secret::blob(secret.as_slice()))
}

fn timed_out(what: &str) -> ashpd::Error {
    ashpd::Error::IO(std::io::Error::new(std::io::ErrorKind::TimedOut, what))
}

#[cfg(test)]
mod tests {
    use oo7::ashpd::desktop::ResponseError;
    use tokio::io::AsyncWriteExt;

    use super::*;

    const WAIT: Duration = Duration::from_secs(5);

    #[tokio::test]
    async fn a_refused_request_returns_without_reading() {
        let (reader, writer) = UnixStream::pair().expect("a socket pair");

        // GNOME Keyring keeps its copy of the write end open after it fails.
        let result = tokio::time::timeout(
            WAIT,
            read_secret(Err(ashpd::Error::Response(ResponseError::Other)), reader),
        )
        .await
        .expect("a refused request must not wait on the socket");

        assert!(
            matches!(result, Err(ashpd::Error::Response(ResponseError::Other))),
            "{result:?}"
        );
        drop(writer);
    }

    #[tokio::test]
    async fn an_answered_request_reads_the_secret() {
        let (reader, mut writer) = UnixStream::pair().expect("a socket pair");
        writer.write_all(&[7; 64]).await.expect("the secret is written");
        drop(writer);

        let secret = tokio::time::timeout(WAIT, read_secret(Ok(()), reader))
            .await
            .expect("the read ends once the writer closes")
            .expect("the secret");

        assert_eq!(secret.as_bytes(), &[7; 64]);
    }

    #[tokio::test(start_paused = true)]
    async fn an_answer_that_keeps_the_socket_open_times_out() {
        let (reader, mut writer) = UnixStream::pair().expect("a socket pair");
        writer.write_all(&[7; 64]).await.expect("the secret is written");

        let result = read_secret(Ok(()), reader).await;

        let Err(ashpd::Error::IO(error)) = result else {
            panic!("expected a timed-out read, got {result:?}");
        };
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        drop(writer);
    }
}
