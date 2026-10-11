use std::{collections::HashMap, marker::PhantomData};

use crate::{
    bson::{Bson, Document},
    error::{BulkWriteError, Error, ErrorKind, Result},
    operation::bulk_write::BulkWrite as BulkWriteOperation,
    options::{BulkWriteOptions, WriteConcern, WriteModel},
    results::{BulkWriteResult, SummaryBulkWriteResult, VerboseBulkWriteResult},
    Client,
    ClientSession,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc};

impl Client {
    /// Executes the provided list of write operations.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<SummaryBulkWriteResult>`] or
    /// d[`Result<VerboseBulkWriteResult>`] if [`verbose_results`](BulkWrite::verbose_results)
    /// is configured.
    ///
    /// Bulk write is only available on MongoDB 8.0+.
    #[deeplink]
    #[options_doc(bulk_write)]
    pub fn bulk_write(
        &self,
        models: impl IntoIterator<Item = impl Into<WriteModel>>,
    ) -> BulkWrite<'_, SummaryBulkWriteResult> {
        let mut models_vec = Vec::new();
        for model in models.into_iter() {
            models_vec.push(model.into());
        }
        BulkWrite::new(self, models_vec)
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Client {
    /// Executes the provided list of write operations.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](BulkWrite::run) will return d[`Result<SummaryBulkWriteResult>`] or
    /// d[`Result<VerboseBulkWriteResult>`] if [`verbose_results`](BulkWrite::verbose_results) is
    /// configured.
    ///
    /// Bulk write is only available on MongoDB 8.0+.
    #[deeplink]
    #[options_doc(bulk_write, "run")]
    pub fn bulk_write(
        &self,
        models: impl IntoIterator<Item = impl Into<WriteModel>>,
    ) -> BulkWrite<'_, SummaryBulkWriteResult> {
        self.async_client.bulk_write(models)
    }
}

/// Performs multiple write operations. Construct with [`Client::bulk_write`].
#[must_use]
pub struct BulkWrite<'a, R> {
    client: &'a Client,
    models: Vec<WriteModel>,
    options: Option<BulkWriteOptions>,
    session: Option<&'a mut ClientSession>,
    _phantom: PhantomData<R>,
}

impl<'a> BulkWrite<'a, SummaryBulkWriteResult> {
    /// Return a [`VerboseBulkWriteResult`] with individual results for each successfully performed
    /// write.
    pub fn verbose_results(self) -> BulkWrite<'a, VerboseBulkWriteResult> {
        BulkWrite {
            client: self.client,
            models: self.models,
            options: self.options,
            session: self.session,
            _phantom: PhantomData,
        }
    }
}

#[option_setters(crate::client::options::BulkWriteOptions)]
#[export_doc(bulk_write, extra = [verbose_results])]
impl<'a, R> BulkWrite<'a, R>
where
    R: BulkWriteResult,
{
    /// Use the provided session when running the operation.
    pub fn session(mut self, session: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(session.into());
        self
    }

    fn new(client: &'a Client, models: Vec<WriteModel>) -> Self {
        Self {
            client,
            models,
            options: None,
            session: None,
            _phantom: PhantomData,
        }
    }

    fn is_ordered(&self) -> bool {
        self.options
            .as_ref()
            .and_then(|options| options.ordered)
            .unwrap_or(true)
    }

    async fn execute_inner(mut self) -> Result<R> {
        let mut total_attempted = 0;
        let mut execution_status = ExecutionStatus::None;

        while total_attempted < self.models.len()
            && execution_status.should_continue(self.is_ordered())
        {
            let mut operation = BulkWriteOperation::new(
                self.client.clone(),
                &self.models[total_attempted..],
                total_attempted,
                self.options.as_ref(),
            )
            .await;
            let result = self
                .client
                .execute_operation::<BulkWriteOperation<R>>(
                    &mut operation,
                    self.session.as_deref_mut(),
                )
                .await;
            total_attempted += operation.n_attempted;

            match result {
                Ok(result) => {
                    execution_status = execution_status.with_success(result);
                }
                Err(error) => {
                    execution_status = execution_status.with_failure(error);
                }
            }
        }

        match execution_status {
            ExecutionStatus::Success(bulk_write_result) => Ok(bulk_write_result),
            ExecutionStatus::Error(error) => Err(error),
            ExecutionStatus::None => Err(ErrorKind::InvalidArgument {
                message: "bulk_write must be provided at least one write operation".into(),
            }
            .into()),
        }
    }
}

#[action_impl]
impl<'a> Action for BulkWrite<'a, SummaryBulkWriteResult> {
    type Future = SummaryBulkWriteFuture;

    async fn execute(mut self) -> Result<SummaryBulkWriteResult> {
        self.execute_inner().await
    }
}

#[action_impl]
impl<'a> Action for BulkWrite<'a, VerboseBulkWriteResult> {
    type Future = VerboseBulkWriteFuture;

    async fn execute(mut self) -> Result<VerboseBulkWriteResult> {
        self.execute_inner().await
    }
}

/// Represents the execution status of a bulk write. The status starts at `None`, indicating that no
/// writes have been attempted yet, and transitions to either `Success` or `Error` as batches are
/// executed. The contents of `Error` can be inspected to determine whether a bulk write can
/// continue with further batches or should be terminated.
enum ExecutionStatus<R>
where
    R: BulkWriteResult,
{
    Success(R),
    Error(Error),
    None,
}

impl<R> ExecutionStatus<R>
where
    R: BulkWriteResult,
{
    fn with_success(mut self, result: R) -> Self {
        match self {
            // Merge two successful sets of results together.
            Self::Success(ref mut current_result) => {
                current_result.merge(result);
                self
            }
            // Merge the results of the new batch into the existing bulk write error.
            Self::Error(ref mut current_error) => {
                let bulk_write_error = Self::get_current_bulk_write_error(current_error);
                bulk_write_error.merge_partial_results(result.into_partial_result());
                self
            }
            Self::None => Self::Success(result),
        }
    }

    fn with_failure(self, mut error: Error) -> Self {
        match self {
            // If the new error is a BulkWriteError, merge the successful results into the error's
            // partial result. Otherwise, create a new BulkWriteError with the existing results and
            // set its source as the error that just occurred.
            Self::Success(current_result) => match *error.kind {
                ErrorKind::BulkWrite(ref mut bulk_write_error) => {
                    bulk_write_error.merge_partial_results(current_result.into_partial_result());
                    Self::Error(error)
                }
                _ => {
                    let bulk_write_error: Error = ErrorKind::BulkWrite(BulkWriteError {
                        write_errors: HashMap::new(),
                        write_concern_errors: Vec::new(),
                        partial_result: Some(current_result.into_partial_result()),
                    })
                    .into();
                    Self::Error(bulk_write_error.with_source(error))
                }
            },
            // If the new error is a BulkWriteError, merge its contents with the existing error.
            // Otherwise, set the new error as the existing error's source.
            Self::Error(mut current_error) => match *error.kind {
                ErrorKind::BulkWrite(bulk_write_error) => {
                    let current_bulk_write_error =
                        Self::get_current_bulk_write_error(&mut current_error);
                    current_bulk_write_error.merge(bulk_write_error);
                    Self::Error(current_error)
                }
                _ => Self::Error(current_error.with_source(error)),
            },
            Self::None => Self::Error(error),
        }
    }

    /// Gets a BulkWriteError from a given Error. This method should only be called when adding a
    /// new result or error to the existing state, as it requires that the given Error's kind is
    /// ClientBulkWrite.
    fn get_current_bulk_write_error(error: &mut Error) -> &mut BulkWriteError {
        match *error.kind {
            ErrorKind::BulkWrite(ref mut bulk_write_error) => bulk_write_error,
            _ => unreachable!(),
        }
    }

    /// Whether further bulk write batches should be executed based on the current status of
    /// execution.
    fn should_continue(&self, ordered: bool) -> bool {
        match self {
            Self::Error(ref error) => {
                match *error.kind {
                    ErrorKind::BulkWrite(ref bulk_write_error) => {
                        // A top-level error is always fatal.
                        let top_level_error_occurred = error.source.is_some();
                        // A write error occurring during an ordered bulk write is fatal.
                        let terminal_write_error_occurred =
                            ordered && !bulk_write_error.write_errors.is_empty();

                        !top_level_error_occurred && !terminal_write_error_occurred
                    }
                    // A top-level error is always fatal.
                    _ => false,
                }
            }
            _ => true,
        }
    }
}
