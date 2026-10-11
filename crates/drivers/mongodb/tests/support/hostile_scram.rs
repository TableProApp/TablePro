use std::time::Duration;

use mongodb::bson::{Binary, Document, doc, spec::BinarySubtype};
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::MongodbDriver;

#[derive(Clone, Copy)]
enum Challenge {
    ShortNonce,
    NonAsciiNonce,
    ExcessiveIterations,
}

impl Challenge {
    fn server_first(self, client_nonce: &str) -> String {
        match self {
            Self::ShortNonce => "r=x,s=c2FsdA==,i=4096".into(),
            Self::NonAsciiNonce => "r=é,s=c2FsdA==,i=4096".into(),
            Self::ExcessiveIterations => {
                format!("r={client_nonce}fixture,s=c2FsdA==,i=100001")
            }
        }
    }
}

#[tokio::test]
async fn mongodb_scram_rejects_hostile_server_challenges_before_sending_proof() {
    for challenge in [
        Challenge::ShortNonce,
        Challenge::NonAsciiNonce,
        Challenge::ExcessiveIterations,
    ] {
        assert_challenge_rejected(challenge).await;
    }
}

async fn assert_challenge_rejected(challenge: Challenge) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("fixture listener");
    let port = listener.local_addr().expect("fixture address").port();
    let (observed_tx, mut observed_rx) = tokio::sync::mpsc::unbounded_channel();
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let observed_tx = observed_tx.clone();
            tokio::spawn(async move {
                handle_connection(stream, challenge, observed_tx).await;
            });
        }
    });

    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        database: "admin".into(),
        username: "bookie".into(),
        password: secrecy::SecretString::new("password".into()),
        ..Default::default()
    };
    let result = tokio::time::timeout(Duration::from_secs(8), MongodbDriver.connect(options))
        .await
        .expect("hostile authentication must finish promptly");
    match result {
        Err(DriverError::AuthFailed) => {}
        Err(error) => panic!("expected auth refusal, got {error:?}"),
        Ok(_) => panic!("hostile authentication must not connect"),
    }

    let proof_sent = tokio::time::timeout(Duration::from_secs(2), observed_rx.recv())
        .await
        .expect("fixture observed the SCRAM challenge")
        .expect("fixture task reported whether a proof was sent");
    assert!(
        !proof_sent,
        "client must reject the challenge before sending its SCRAM proof"
    );
    server.abort();
}

async fn handle_connection(
    mut stream: TcpStream,
    challenge: Challenge,
    observed_tx: tokio::sync::mpsc::UnboundedSender<bool>,
) {
    loop {
        let Ok((request_id, command)) = read_message(&mut stream).await else {
            return;
        };
        let Some(auth) = command.get_document("speculativeAuthenticate").ok() else {
            if send_hello(&mut stream, request_id, None).await.is_err() {
                return;
            }
            continue;
        };
        let Ok(payload) = auth.get_binary_generic("payload") else {
            return;
        };
        let Ok(initial) = std::str::from_utf8(payload) else {
            return;
        };
        let Some(client_nonce) = initial.split(',').find_map(|part| part.strip_prefix("r=")) else {
            return;
        };
        let server_first = challenge.server_first(client_nonce);
        if send_hello(&mut stream, request_id, Some(server_first)).await.is_err() {
            return;
        }

        let proof_sent = matches!(
            tokio::time::timeout(Duration::from_millis(500), read_message(&mut stream)).await,
            Ok(Ok(_))
        );
        let _ = observed_tx.send(proof_sent);
        return;
    }
}

async fn read_message(stream: &mut TcpStream) -> std::io::Result<(i32, Document)> {
    let mut header = [0; 16];
    stream.read_exact(&mut header).await?;
    let length = i32::from_le_bytes(header[0..4].try_into().expect("header length"));
    let request_id = i32::from_le_bytes(header[4..8].try_into().expect("request ID"));
    let opcode = i32::from_le_bytes(header[12..16].try_into().expect("opcode"));
    if length < 21 || opcode != 2013 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "expected MongoDB OP_MSG",
        ));
    }
    let mut body = vec![0; (length - 16) as usize];
    stream.read_exact(&mut body).await?;
    if body[4] != 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "expected OP_MSG document section",
        ));
    }
    let command = mongodb::bson::from_slice(&body[5..])
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    Ok((request_id, command))
}

async fn send_hello(stream: &mut TcpStream, response_to: i32, server_first: Option<String>) -> std::io::Result<()> {
    let mut response = doc! {
        "ok": 1,
        "helloOk": true,
        "isWritablePrimary": true,
        "minWireVersion": 0,
        "maxWireVersion": 21,
        "maxBsonObjectSize": 16777216,
        "maxMessageSizeBytes": 48000000,
        "maxWriteBatchSize": 100000,
        "logicalSessionTimeoutMinutes": 30,
    };
    if let Some(payload) = server_first {
        response.insert(
            "speculativeAuthenticate",
            doc! {
                "ok": 1,
                "conversationId": 1,
                "done": false,
                "payload": Binary {
                    subtype: BinarySubtype::Generic,
                    bytes: payload.into_bytes(),
                },
            },
        );
    }
    let document = mongodb::bson::to_vec(&response)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    let length = 16 + 4 + 1 + document.len();
    stream.write_all(&(length as i32).to_le_bytes()).await?;
    stream.write_all(&1i32.to_le_bytes()).await?;
    stream.write_all(&response_to.to_le_bytes()).await?;
    stream.write_all(&2013i32.to_le_bytes()).await?;
    stream.write_all(&0u32.to_le_bytes()).await?;
    stream.write_all(&[0]).await?;
    stream.write_all(&document).await?;
    stream.flush().await
}
