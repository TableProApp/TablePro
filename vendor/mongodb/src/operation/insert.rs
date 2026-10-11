use std::collections::HashMap;

use crate::{
    bson::{rawdoc, Bson, Document, RawDocument},
    bson_compat::{cstr, CStr},
    bson_util::{
        array_entry_size_bytes,
        extend_raw_document_buf,
        get_or_prepend_id_field,
        vec_to_raw_array_buf,
    },
    checked::Checked,
    cmap::{Command, RawCommandResponse, StreamDescription},
    error::{ErrorKind, Result},
    operation::{Base, BaseOperation, OperationImpl, Retryability},
    options::{ClientOptions, InsertManyOptions, WriteConcern},
    results::InsertManyResult,
    Collection,
};

use super::{ExecutionContext, MAX_ENCRYPTED_WRITE_SIZE, OP_MSG_OVERHEAD_BYTES};

#[derive(Debug)]
pub(crate) struct Insert<'a> {
    target: Collection<Document>,
    documents: Vec<&'a RawDocument>,
    inserted_ids: Vec<Bson>,
    options: InsertManyOptions,
    encrypted: bool,
}

impl<'a> Insert<'a> {
    pub(crate) fn new(
        target: Collection<Document>,
        documents: Vec<&'a RawDocument>,
        options: Option<InsertManyOptions>,
        encrypted: bool,
    ) -> Self {
        let mut options = options.unwrap_or_default();
        if options.ordered.is_none() {
            options.ordered = Some(true);
        }

        Self {
            target,
            options,
            documents,
            inserted_ids: vec![],
            encrypted,
        }
    }
}

impl BaseOperation for Insert<'_> {
    type O = InsertManyResult;

    const NAME: &'static CStr = cstr!("insert");

    fn build(&mut self, description: &StreamDescription) -> Result<Command> {
        self.inserted_ids.clear();

        let max_doc_size: usize = Checked::new(description.max_bson_object_size).try_into()?;
        let max_message_size: usize =
            Checked::new(description.max_message_size_bytes).try_into()?;
        let max_operations: usize = Checked::new(description.max_write_batch_size).try_into()?;

        let mut command_body = rawdoc! { Self::NAME: self.target.name() };
        let options = crate::bson_compat::serialize_to_raw_document_buf(&self.options)?;
        extend_raw_document_buf(&mut command_body, options)?;

        let max_document_sequence_size: usize = (Checked::new(max_message_size)
            - OP_MSG_OVERHEAD_BYTES
            - command_body.as_bytes().len())
        .try_into()?;

        let mut docs = Vec::new();
        let mut current_size = Checked::new(0);
        for (i, document) in self.documents.iter().take(max_operations).enumerate() {
            let mut document = crate::bson_compat::serialize_to_raw_document_buf(document)?;
            let id = get_or_prepend_id_field(&mut document)?;

            let doc_size = document.as_bytes().len();
            if doc_size > max_doc_size {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "insert document must be within {max_doc_size} bytes, but document \
                         provided is {doc_size} bytes"
                    ),
                }
                .into());
            }

            // From the spec: Drivers MUST not reduce the size limits for a single write before
            // automatic encryption. I.e. if a single document has size larger than 2MiB (but less
            // than `maxBsonObjectSize`) proceed with automatic encryption.
            if self.encrypted {
                let doc_entry_size = array_entry_size_bytes(i, document.as_bytes().len())?;
                current_size += doc_entry_size;
                if i != 0 && current_size.get()? >= MAX_ENCRYPTED_WRITE_SIZE {
                    break;
                }
            } else {
                current_size += doc_size;
                if current_size.get()? > max_document_sequence_size {
                    break;
                }
            }

            self.inserted_ids.push(id);
            docs.push(document);
        }

        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
        };

        let options_doc = crate::bson_compat::serialize_to_raw_document_buf(&self.options)?;
        extend_raw_document_buf(&mut body, options_doc)?;

        if self.encrypted {
            // Auto-encryption does not support document sequences
            body.append(cstr!("documents"), vec_to_raw_array_buf(docs));
            Ok(Command::from_operation(self, body))
        } else {
            let mut command = Command::from_operation(self, body);
            command.add_document_sequence("documents", docs);
            Ok(command)
        }
    }

    fn handle_response<'b>(
        &'b self,
        response: &'b RawCommandResponse,
        _context: ExecutionContext<'b>,
    ) -> Result<Self::O> {
        let n: usize = Checked::new(response.extract_n()?).try_into()?;
        let inserted_ids = || {
            self.inserted_ids
                .iter()
                .cloned()
                .enumerate()
                .take(n)
                .collect()
        };

        match response.validate_insert_many() {
            Ok(()) => Ok(InsertManyResult {
                inserted_ids: inserted_ids(),
            }),
            Err(mut error) => {
                if let ErrorKind::InsertMany(ref mut insert_many_error) = *error.kind {
                    let inserted_ids = if self.options.ordered == Some(false) {
                        let mut all_inserted_ids: HashMap<_, _> =
                            self.inserted_ids.iter().cloned().enumerate().collect();
                        if let Some(ref write_errors) = insert_many_error.write_errors {
                            for write_error in write_errors {
                                all_inserted_ids.remove(&write_error.index);
                            }
                        }
                        all_inserted_ids
                    } else {
                        inserted_ids()
                    };
                    insert_many_error.inserted_ids = inserted_ids;
                };
                Err(error)
            }
        }
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options.write_concern.as_ref().into()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        Retryability::write(options)
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for Insert<'_> {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Insert<'_> {}
