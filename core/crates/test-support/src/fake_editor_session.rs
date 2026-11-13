use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, CopyInPiece, CopyInRows, CopyInSummary, DriverError, EditorSession, EditorSessionId,
    EditorSessionState, ErrorCategory, LossPhase, ResultEvent, ResultSink, RunEnd, RunOptions, RunSummary, SinkFlow,
    TimeoutPhase, TransactionState, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::fake_reply::Stop;
use crate::{CloseBehaviour, FakeCopyIn, FakeRun, Replies, RunWait, lock};

/// An `EditorSession` that answers each run from a script and records
/// what it was asked to run.
///
/// It keeps the session rules the editor relies on: one run at a time,
/// a lost session stays lost, and the transaction state is whatever the
/// last run left.
///
/// A copy answers from the same script, by its statement. One scripted
/// to end other than `Completed` refuses the COPY before it takes any
/// rows, as a server refuses a missing table, and lets go of them once
/// its scripted wait is over; the rest take every row up to the end and
/// then answer.
#[derive(Debug)]
pub struct FakeEditorSession {
    id: EditorSessionId,
    runs: Mutex<Replies<FakeRun>>,
    texts: Mutex<Vec<UserSql>>,
    copies: Mutex<Vec<FakeCopyIn>>,
    state: Mutex<EditorSessionState>,
    transaction_state: Mutex<TransactionState>,
    database: Mutex<Option<String>>,
    moves: Mutex<Vec<String>>,
    refused_moves: Mutex<Option<DriverError>>,
    close_behaviour: CloseBehaviour,
    closes: AtomicUsize,
    closed: AtomicBool,
    stopped_runs: AtomicUsize,
    closing: CancellationToken,
}

impl FakeEditorSession {
    pub fn new(runs: Replies<FakeRun>) -> Self {
        Self::with_close(runs, CloseBehaviour::Immediate)
    }

    pub fn with_close(runs: Replies<FakeRun>, close_behaviour: CloseBehaviour) -> Self {
        Self {
            id: EditorSessionId::new(),
            runs: Mutex::new(runs),
            texts: Mutex::new(Vec::new()),
            copies: Mutex::new(Vec::new()),
            state: Mutex::new(EditorSessionState::Ready),
            transaction_state: Mutex::new(TransactionState::Idle),
            database: Mutex::new(None),
            moves: Mutex::new(Vec::new()),
            refused_moves: Mutex::new(None),
            close_behaviour,
            closes: AtomicUsize::new(0),
            closed: AtomicBool::new(false),
            stopped_runs: AtomicUsize::new(0),
            closing: CancellationToken::new(),
        }
    }

    /// The text of every run and every copy's statement, in the order
    /// they started.
    pub fn texts(&self) -> Vec<UserSql> {
        lock(&self.texts).clone()
    }

    /// Every copy, with the rows it took so far.
    pub fn copies(&self) -> Vec<FakeCopyIn> {
        lock(&self.copies).clone()
    }

    pub fn close_count(&self) -> usize {
        self.closes.load(Ordering::SeqCst)
    }

    /// Set once a close has finished, delay included.
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Runs that ended because they were cancelled or ran out of time.
    pub fn stopped_runs(&self) -> usize {
        self.stopped_runs.load(Ordering::SeqCst)
    }

    pub fn set_transaction_state(&self, state: TransactionState) {
        *lock(&self.transaction_state) = state;
    }

    /// Where the session says it is, as after a `USE`.
    pub fn set_database(&self, database: Option<&str>) {
        *lock(&self.database) = database.map(str::to_owned);
    }

    /// The databases `use_database` moved the session to, in order.
    pub fn moves(&self) -> Vec<String> {
        lock(&self.moves).clone()
    }

    /// Every later `use_database` fails with `error`.
    pub fn refuse_moves(&self, error: DriverError) {
        *lock(&self.refused_moves) = Some(error);
    }

    /// The connection goes while no run is on it, as when the server
    /// ends a session left idle in a transaction.
    pub fn lose(&self) {
        *lock(&self.state) = EditorSessionState::Lost;
    }

    fn begin(&self) -> Result<RunningGuard<'_>, DriverError> {
        let mut state = lock(&self.state);
        match *state {
            EditorSessionState::Ready => {
                *state = EditorSessionState::Running;
                Ok(RunningGuard { session: self })
            }
            EditorSessionState::Running => Err(DriverError::EditorSessionBusy),
            EditorSessionState::Lost => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
        }
    }

    async fn play(&self, run: FakeRun, options: &RunOptions, sink: &mut dyn ResultSink) -> Result<RunEnd, DriverError> {
        let stop = Stop {
            deadline: options.deadline.map(|deadline| Instant::now() + deadline),
            cancel: &options.cancel,
            closed: &self.closing,
            phase: TimeoutPhase::Statement,
        };
        let waited = match run.wait {
            RunWait::None => Ok(()),
            RunWait::For(duration) => stop.wait(Some(duration)).await,
            RunWait::UntilStopped => stop.wait(None).await,
        };
        match waited {
            Err(DriverError::Timeout { server_cancelled, .. }) => return Ok(RunEnd::TimedOut { server_cancelled }),
            Err(DriverError::Cancelled) => return Ok(RunEnd::Cancelled),
            Err(other) => return Err(other),
            Ok(()) => {}
        }
        for event in run.events {
            if sink.accept(event).await == SinkFlow::ConsumerGone {
                return Ok(RunEnd::Cancelled);
            }
        }
        *lock(&self.transaction_state) = run.transaction_state;
        run.end
    }

    /// What the end of a run or a copy leaves the session in.
    fn settle(&self, loses_session: bool, end: &Result<RunEnd, DriverError>) {
        if loses_session {
            *lock(&self.state) = EditorSessionState::Lost;
        }
        match end {
            Ok(RunEnd::Cancelled | RunEnd::TimedOut { .. }) => {
                self.stopped_runs.fetch_add(1, Ordering::SeqCst);
            }
            Err(error) if error.category() == ErrorCategory::ConnectionLost => {
                *lock(&self.state) = EditorSessionState::Lost;
            }
            _ => {}
        }
    }

    /// Take the rows of copy `index` up to their end. False when the copy
    /// was cancelled or its source gave up first.
    async fn take_rows(&self, index: usize, rows: &mut CopyInRows, options: &RunOptions) -> bool {
        loop {
            let piece = tokio::select! {
                biased;
                () = options.cancel.cancelled() => return false,
                () = self.closing.cancelled() => return false,
                piece = rows.recv() => piece,
            };
            let mut copies = lock(&self.copies);
            let Some(copy) = copies.get_mut(index) else {
                return false;
            };
            match piece {
                Some(CopyInPiece::Data(bytes)) => {
                    copy.data.extend_from_slice(&bytes);
                    copy.pieces += 1;
                }
                Some(CopyInPiece::End) => {
                    copy.ended = true;
                    return true;
                }
                None => return false,
            }
        }
    }
}

/// Lines of COPY data, a last one without a line break included.
fn rows_in(data: &[u8]) -> u64 {
    let breaks = data.iter().filter(|byte| **byte == b'\n').count() as u64;
    breaks + u64::from(data.last().is_some_and(|byte| *byte != b'\n'))
}

/// Where the events of a copy's scripted run go.
struct Discard;

#[async_trait]
impl ResultSink for Discard {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}

/// Puts the session back to Ready however the run ends, including when
/// the caller drops the run halfway.
struct RunningGuard<'a> {
    session: &'a FakeEditorSession,
}

impl Drop for RunningGuard<'_> {
    fn drop(&mut self) {
        let mut state = lock(&self.session.state);
        if *state == EditorSessionState::Running {
            *state = EditorSessionState::Ready;
        }
    }
}

#[async_trait]
impl EditorSession for FakeEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        *lock(&self.state)
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        mut sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let started = Instant::now();
        let _running = self.begin()?;
        lock(&self.texts).push(sql.clone());
        let run = lock(&self.runs).next(Some(sql.as_str()));
        let Some(run) = run else {
            return Err(DriverError::Protocol(
                "FakeEditorSession has no scripted run".to_owned(),
            ));
        };
        let loses_session = run.loses_session;
        let end = self.play(run, &options, sink.as_mut()).await;
        self.settle(loses_session, &end);
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end: end?,
            transaction_state: *lock(&self.transaction_state),
        })
    }

    async fn copy_in(
        &self,
        statement: UserSql,
        mut rows: CopyInRows,
        options: RunOptions,
    ) -> Result<CopyInSummary, DriverError> {
        let _running = self.begin()?;
        lock(&self.texts).push(statement.clone());
        let index = {
            let mut copies = lock(&self.copies);
            copies.push(FakeCopyIn {
                statement: statement.clone(),
                data: Vec::new(),
                pieces: 0,
                ended: false,
            });
            copies.len() - 1
        };
        let run = lock(&self.runs).next(Some(statement.as_str()));
        let Some(run) = run else {
            return Err(DriverError::Protocol(
                "FakeEditorSession has no scripted run".to_owned(),
            ));
        };
        let refused = !matches!(run.end, Ok(RunEnd::Completed));
        if !refused && !self.take_rows(index, &mut rows, &options).await {
            self.stopped_runs.fetch_add(1, Ordering::SeqCst);
            return Ok(CopyInSummary {
                end: RunEnd::Cancelled,
                rows: 0,
                transaction_state: *lock(&self.transaction_state),
            });
        }
        let loses_session = run.loses_session;
        let end = self.play(run, &options, &mut Discard).await;
        drop(rows);
        self.settle(loses_session, &end);
        let end = end?;
        let copied = match end {
            RunEnd::Completed => lock(&self.copies).get(index).map_or(0, |copy| rows_in(&copy.data)),
            _ => 0,
        };
        Ok(CopyInSummary {
            end,
            rows: copied,
            transaction_state: *lock(&self.transaction_state),
        })
    }

    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        Ok(*lock(&self.transaction_state))
    }

    fn database(&self) -> Option<String> {
        lock(&self.database).clone()
    }

    async fn use_database(&self, database: &str, _options: CallOptions) -> Result<(), DriverError> {
        if let Some(error) = lock(&self.refused_moves).clone() {
            return Err(error);
        }
        lock(&self.moves).push(database.to_owned());
        *lock(&self.database) = Some(database.to_owned());
        Ok(())
    }

    async fn close(&self) {
        let first = self.closes.fetch_add(1, Ordering::SeqCst) == 0;
        self.closing.cancel();
        *lock(&self.state) = EditorSessionState::Lost;
        if first {
            self.close_behaviour.run().await;
        }
        self.closed.store(true, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use futures::future::BoxFuture;
    use tablepro_core::RowLimit;
    use tablepro_core::value::Value;
    use tokio::sync::mpsc;
    use tokio_util::bytes::Bytes;

    use super::*;
    use crate::close_race::{ROUNDS, pending_closes};

    fn run_options() -> RunOptions {
        RunOptions::new(CancellationToken::new())
    }

    #[tokio::test]
    async fn runs_are_recorded_and_leave_their_transaction_state() {
        let mut runs = Replies::default();
        runs.when_sql_contains(
            "BEGIN",
            FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction),
        )
        .always(FakeRun::completed(vec![ResultEvent::Rows(vec![vec![Value::Int(1)]])]));
        let session = FakeEditorSession::new(runs);

        let begun = session
            .run(UserSql::new("BEGIN"), run_options(), Box::new(Discard))
            .await
            .unwrap();
        let selected = session
            .run(
                UserSql::new("SELECT 1"),
                run_options().with_row_limit(RowLimit::EDITOR_DEFAULT),
                Box::new(Discard),
            )
            .await
            .unwrap();

        assert_eq!(begun.transaction_state, TransactionState::InTransaction);
        assert_eq!(selected.end, RunEnd::Completed);
        assert_eq!(session.texts(), vec![UserSql::new("BEGIN"), UserSql::new("SELECT 1")]);
        assert_eq!(session.state(), EditorSessionState::Ready);
    }

    #[tokio::test]
    async fn a_copy_takes_its_rows_and_a_refused_one_takes_none() {
        let mut runs = Replies::default();
        runs.when_sql_contains(
            "missing",
            FakeRun::failed(DriverError::Protocol("no such table".to_owned())),
        )
        .always(FakeRun::completed(Vec::new()));
        let session = FakeEditorSession::new(runs);
        let (sender, rows) = mpsc::channel(4);
        sender
            .send(CopyInPiece::Data(Bytes::from_static(b"1\tone\n2")))
            .await
            .unwrap();
        sender.send(CopyInPiece::End).await.unwrap();
        let (_unread, refused_rows) = mpsc::channel(1);

        let copied = session
            .copy_in(UserSql::new("COPY t FROM stdin"), rows, run_options())
            .await
            .unwrap();
        let refused = session
            .copy_in(UserSql::new("COPY missing FROM stdin"), refused_rows, run_options())
            .await
            .unwrap();

        assert_eq!(copied.end, RunEnd::Completed);
        assert_eq!(copied.rows, 2);
        assert!(matches!(refused.end, RunEnd::Failed(_)), "{refused:?}");
        let copies = session.copies();
        assert_eq!(copies[0].data, b"1\tone\n2");
        assert!(copies[0].ended);
        assert!(!copies[1].ended);
        assert_eq!(session.state(), EditorSessionState::Ready);
    }

    #[tokio::test]
    async fn a_copy_whose_source_closes_before_the_end_is_cancelled() {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()));
        let session = FakeEditorSession::new(runs);
        let (sender, rows) = mpsc::channel(4);
        sender
            .send(CopyInPiece::Data(Bytes::from_static(b"1\n")))
            .await
            .unwrap();
        drop(sender);

        let copied = session
            .copy_in(UserSql::new("COPY t FROM stdin"), rows, run_options())
            .await
            .unwrap();

        assert_eq!(copied.end, RunEnd::Cancelled);
        assert_eq!(session.copies()[0].data, b"1\n");
        assert!(!session.copies()[0].ended);
        assert_eq!(session.stopped_runs(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn a_second_run_while_one_is_running_is_busy_and_cancel_is_observed() {
        let mut runs = Replies::default();
        runs.always(FakeRun::until_stopped());
        let session = Arc::new(FakeEditorSession::new(runs));
        let cancel = CancellationToken::new();
        let first = {
            let session = session.clone();
            let options = RunOptions::new(cancel.clone());
            tokio::spawn(async move {
                session
                    .run(UserSql::new("SELECT pg_sleep(60)"), options, Box::new(Discard))
                    .await
            })
        };
        tokio::time::sleep(Duration::from_millis(10)).await;

        let second = session
            .run(UserSql::new("SELECT 1"), run_options(), Box::new(Discard))
            .await;
        cancel.cancel();
        let first = first.await.unwrap().unwrap();

        assert!(matches!(second, Err(DriverError::EditorSessionBusy)));
        assert_eq!(first.end, RunEnd::Cancelled);
        assert_eq!(session.stopped_runs(), 1);
        assert_eq!(session.state(), EditorSessionState::Ready);
    }

    #[tokio::test]
    async fn a_lost_connection_leaves_the_session_lost() {
        let mut runs = Replies::default();
        runs.always(FakeRun::session_error(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
        let session = FakeEditorSession::new(runs);

        let lost = session
            .run(UserSql::new("SELECT 1"), run_options(), Box::new(Discard))
            .await;
        let after = session
            .run(UserSql::new("SELECT 1"), run_options(), Box::new(Discard))
            .await;

        assert!(matches!(lost, Err(DriverError::ConnectionLost { .. })));
        assert!(matches!(
            after,
            Err(DriverError::ConnectionLost {
                during: LossPhase::Idle
            })
        ));
        assert_eq!(session.state(), EditorSessionState::Lost);
    }

    #[tokio::test(start_paused = true)]
    async fn a_delayed_close_sets_the_closed_flag_only_when_it_finishes() {
        let session = Arc::new(FakeEditorSession::with_close(
            Replies::default(),
            CloseBehaviour::Delay(Duration::from_millis(100)),
        ));
        let closing = {
            let session = session.clone();
            tokio::spawn(async move { session.close().await })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!session.is_closed());

        closing.await.unwrap();
        session.close().await;

        assert!(session.is_closed());
        assert_eq!(session.close_count(), 2);
        assert_eq!(session.state(), EditorSessionState::Lost);
    }

    fn close_session(session: &FakeEditorSession) -> BoxFuture<'_, ()> {
        session.close()
    }

    #[test]
    fn concurrent_closes_run_the_close_behaviour_once() {
        let pending = pending_closes(
            ROUNDS,
            || FakeEditorSession::with_close(Replies::default(), CloseBehaviour::Hang),
            close_session,
        );

        assert!(pending.iter().all(|&hung| hung == 1), "{pending:?}");
    }
}
