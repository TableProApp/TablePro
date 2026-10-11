use std::collections::HashMap;

use serde::{de::DeserializeOwned, Deserialize, Serialize};

use super::wire::{message::DocumentSequence, Message};
use crate::{
    bson::{Document, RawDocument, RawDocumentBuf},
    bson_compat::{deserialize_from_slice, Utf8Lossy},
    bson_util::get_u64_raw,
    client::{options::ServerApi, ClusterTime},
    error::{
        Error,
        ErrorKind,
        IndexedWriteError,
        InsertManyError,
        Result,
        WriteConcernError,
        WriteFailure,
    },
    hello::{HelloCommandResponse, HelloReply},
    operation::{CommandErrorBody, CommandResponse, Feature, Operation},
    options::{ReadConcernInternal, ReadConcernLevel, ServerAddress, WriteConcern},
    selection_criteria::ReadPreference,
    ClientSession,
};

/// Driver-side model of a database command.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Command {
    #[serde(skip)]
    pub(crate) name: String,

    #[serde(skip)]
    pub(crate) exhaust_allowed: bool,

    #[serde(flatten)]
    pub(crate) body: RawDocumentBuf,

    #[serde(skip)]
    pub(crate) document_sequences: Vec<DocumentSequence>,

    #[serde(rename = "$db")]
    pub(crate) target_db: String,

    pub(crate) lsid: Option<Document>,

    #[serde(rename = "$clusterTime")]
    cluster_time: Option<ClusterTime>,

    #[serde(flatten)]
    server_api: Option<ServerApi>,

    #[serde(rename = "$readPreference")]
    read_preference: Option<ReadPreference>,

    pub(crate) txn_number: Option<i64>,

    start_transaction: Option<bool>,

    autocommit: Option<bool>,

    read_concern: Option<ReadConcernInternal>,

    #[serde(skip_serializing_if = "write_concern_is_empty")]
    write_concern: Option<WriteConcern>,

    recovery_token: Option<Document>,
}

fn write_concern_is_empty(write_concern: &Option<WriteConcern>) -> bool {
    write_concern
        .as_ref()
        .is_none_or(|write_concern| write_concern.is_empty())
}

impl Command {
    pub(crate) fn new_raw(
        name: impl ToString,
        target_db: impl ToString,
        body: RawDocumentBuf,
    ) -> Self {
        Self {
            name: name.to_string(),
            target_db: target_db.to_string(),
            exhaust_allowed: false,
            body,
            document_sequences: Vec::new(),
            lsid: None,
            cluster_time: None,
            server_api: None,
            read_preference: None,
            txn_number: None,
            start_transaction: None,
            autocommit: None,
            read_concern: None,
            write_concern: None,
            recovery_token: None,
        }
    }

    pub(crate) fn from_operation<Op: Operation>(op: &Op, body: RawDocumentBuf) -> Self {
        let target = op.target();
        let read_concern = match op.read_concern() {
            Feature::Set(v) => Some(v),
            Feature::NotSupported => None,
            Feature::Inherit => target.read_concern(),
        }
        .cloned()
        .map(ReadConcernInternal::from);
        let write_concern = match op.write_concern() {
            Feature::Set(v) => Some(v),
            Feature::NotSupported => None,
            Feature::Inherit => target.write_concern(),
        }
        .cloned();
        Self {
            name: crate::bson_compat::cstr_to_str(op.name()).to_owned(),
            target_db: target.db_name().to_owned(),
            exhaust_allowed: false,
            body,
            document_sequences: Vec::new(),
            lsid: None,
            cluster_time: None,
            server_api: None,
            read_preference: None,
            txn_number: None,
            start_transaction: None,
            autocommit: None,
            read_concern,
            write_concern,
            recovery_token: None,
        }
    }

    pub(crate) fn add_document_sequence(
        &mut self,
        identifier: impl ToString,
        documents: Vec<RawDocumentBuf>,
    ) {
        self.document_sequences.push(DocumentSequence {
            identifier: identifier.to_string(),
            documents,
        });
    }

    pub(crate) fn set_session(&mut self, session: &ClientSession) {
        self.lsid = Some(session.id().clone())
    }

    pub(crate) fn set_cluster_time(&mut self, cluster_time: &ClusterTime) {
        self.cluster_time = Some(cluster_time.clone());
    }

    pub(crate) fn set_recovery_token(&mut self, recovery_token: &Document) {
        self.recovery_token = Some(recovery_token.clone());
    }

    pub(crate) fn set_txn_number(&mut self, txn_number: i64) {
        self.txn_number = Some(txn_number);
    }

    pub(crate) fn set_server_api(&mut self, server_api: &ServerApi) {
        self.server_api = Some(server_api.clone());
    }

    pub(crate) fn set_read_preference(&mut self, read_preference: ReadPreference) {
        self.read_preference = Some(read_preference);
    }

    pub(crate) fn set_start_transaction(&mut self) {
        self.start_transaction = Some(true);
    }

    pub(crate) fn set_autocommit(&mut self) {
        self.autocommit = Some(false);
    }

    pub(crate) fn clear_concerns(&mut self) {
        self.read_concern = None;
        self.write_concern = None;
    }

    /// Sets the read concern level for this command.
    /// This does not overwrite any other read concern options.
    pub(crate) fn set_read_concern_level(&mut self, level: ReadConcernLevel) {
        let inner = self.read_concern.get_or_insert(ReadConcernInternal {
            level: None,
            at_cluster_time: None,
            after_cluster_time: None,
        });
        inner.level = Some(level);
    }

    /// Sets the read concern level for this command to "snapshot" and sets the `atClusterTime`
    /// field.
    pub(crate) fn set_snapshot_read_concern(&mut self, session: &ClientSession) {
        let inner = self.read_concern.get_or_insert(ReadConcernInternal {
            level: Some(ReadConcernLevel::Snapshot),
            at_cluster_time: None,
            after_cluster_time: None,
        });
        inner.at_cluster_time = session.snapshot_time;
    }

    pub(crate) fn set_after_cluster_time(&mut self, session: &ClientSession) {
        if let Some(operation_time) = session.operation_time {
            let inner = self.read_concern.get_or_insert(ReadConcernInternal {
                level: None,
                at_cluster_time: None,
                after_cluster_time: None,
            });
            inner.after_cluster_time = Some(operation_time);
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct RawCommandResponse {
    pub(crate) source: ServerAddress,
    raw: RawDocumentBuf,
}

/// A helper struct to deserialize write-error-specific fields from a server response.
#[derive(Debug, Deserialize)]
pub(crate) struct WriteErrorBody {
    #[serde(rename = "writeErrors")]
    pub(crate) write_errors: Option<Utf8Lossy<Vec<IndexedWriteError>>>,
    #[serde(rename = "writeConcernError")]
    pub(crate) write_concern_error: Option<Utf8Lossy<WriteConcernError>>,
    #[serde(rename = "errorLabels")]
    pub(crate) labels: Option<Vec<String>>,
}

impl RawCommandResponse {
    #[cfg(test)]
    pub(crate) fn with_document_and_address(source: ServerAddress, doc: Document) -> Result<Self> {
        let mut raw = vec![];
        doc.to_writer(&mut raw)?;
        Ok(Self {
            source,
            raw: RawDocumentBuf::from_bytes(raw)?,
        })
    }

    pub(crate) fn new(source: ServerAddress, message: Message) -> Self {
        Self::new_raw(source, message.document_payload)
    }

    pub(crate) fn new_raw(source: ServerAddress, raw: RawDocumentBuf) -> Self {
        Self { source, raw }
    }

    pub(crate) fn body<'a, T: Deserialize<'a>>(&'a self) -> Result<T> {
        deserialize_from_slice(self.raw.as_bytes()).map_err(|e| {
            Error::from(ErrorKind::InvalidResponse {
                message: format!("{e}"),
            })
        })
    }

    pub(crate) fn validate_single_write(&self) -> Result<()> {
        let body: WriteErrorBody = self.body()?;

        if let Some(write_error) = body
            .write_errors
            .and_then(|write_errors| write_errors.0.into_iter().next())
        {
            Err(Error::new(
                ErrorKind::Write(WriteFailure::WriteError(write_error.into())),
                body.labels,
            ))
        } else if let Some(write_concern_error) = body.write_concern_error {
            Err(Error::new(
                ErrorKind::Write(WriteFailure::WriteConcernError(write_concern_error.0)),
                body.labels,
            ))
        } else {
            Ok(())
        }
    }

    pub(crate) fn validate_insert_many(&self) -> Result<()> {
        let body: WriteErrorBody = self.body()?;

        if body.write_errors.is_none() && body.write_concern_error.is_none() {
            return Ok(());
        }

        Err(Error::new(
            ErrorKind::InsertMany(InsertManyError {
                write_errors: body.write_errors.map(|lossy| lossy.0),
                write_concern_error: body.write_concern_error.map(|lossy| lossy.0),
                inserted_ids: HashMap::new(),
            }),
            body.labels,
        ))
    }

    pub(crate) fn extract_n(&self) -> Result<u64> {
        let Some(n) = self.raw.get("n")? else {
            return Err(Error::invalid_response(
                "expected n field in server response",
            ));
        };
        get_u64_raw(&n).ok_or_else(|| {
            Error::invalid_response(format!("expected numeric value for n, got {n:?}"))
        })
    }

    pub(crate) fn raw_body(&self) -> &RawDocument {
        &self.raw
    }

    pub(crate) fn as_bytes(&self) -> &[u8] {
        self.raw.as_bytes()
    }

    /// Deserialize the body of this response, returning an authentication error if it fails.
    pub(crate) fn auth_response_body<T: DeserializeOwned>(
        &self,
        mechanism_name: &str,
    ) -> Result<T> {
        self.body()
            .map_err(|_| Error::invalid_authentication_response(mechanism_name))
    }

    pub(crate) fn into_hello_reply(self) -> Result<HelloReply> {
        match self.body::<CommandResponse<HelloCommandResponse>>() {
            Ok(response) if response.is_success() => {
                let server_address = self.source_address().clone();
                let cluster_time = response.cluster_time().cloned();
                Ok(HelloReply {
                    server_address,
                    command_response: response.body,
                    cluster_time,
                    raw_command_response: self.into_raw_document_buf(),
                })
            }
            _ => match self.body::<CommandResponse<CommandErrorBody>>() {
                Ok(command_error_body) => Err(Error::new(
                    ErrorKind::Command(command_error_body.body.command_error),
                    command_error_body.body.error_labels,
                )),
                Err(_) => Err(ErrorKind::InvalidResponse {
                    message: "invalid server response".into(),
                }
                .into()),
            },
        }
    }

    /// The address of the server that sent this response.
    pub(crate) fn source_address(&self) -> &ServerAddress {
        &self.source
    }

    pub(crate) fn into_raw_document_buf(self) -> RawDocumentBuf {
        self.raw
    }
}
