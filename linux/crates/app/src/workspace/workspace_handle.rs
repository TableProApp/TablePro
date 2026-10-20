use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;

use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use tablepro_core::ddl::{BuildDdlError, ChangeReview};
use tablepro_core::save::{SavePlan, plan_save};
use tablepro_core::statement::Statement;
use tablepro_core::value::same_value;
use tablepro_core::{CommitResolution, DriverError, SafeModeLevel, WriteKind, WriteReport};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{OperationError, OperationKind, Session};
use tablepro_storage::query_history::Outcome;
use uuid::Uuid;

use super::ran_statements::RanStatements;
use super::schema_write::run_schema_plan;
use super::{
    CloseBlocker, CloseScope, CloseStep, DirtyKind, DirtyTab, EngineProfile, PendingState, RollbackCause, SaveId,
    SaveLedger, SaveOutcome, SaveRejection, SaveSettled, SaveStart, SaveTicket, TabDirectory, UnknownCause,
    WorkspaceEvent, next_close_step,
};
use crate::services::active_session::ActiveSession;
use crate::services::change_origins::ChangeOrigins;
use crate::services::change_tracker::{StatementSource, TrackedChanges, pk_identity};
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::history_service::HistoryService;
use crate::services::structure_tracker_handle::StructureTrackerHandle;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::review_dialog::{self, ReviewDecision};
use crate::ui::write_confirmation::{self, WriteConfirmation};

/// What a window's workspace saves and closes with.
pub struct WorkspaceDeps {
    pub session: ActiveSession,
    pub tasks: Tasks,
    pub hold: Rc<dyn ProcessHold>,
    pub history: Option<HistoryService>,
    pub rows: Rc<ChangeTrackerRegistry>,
    pub structures: Rc<StructureTrackerRegistry>,
    pub directory: Rc<dyn TabDirectory>,
    pub events: Rc<dyn Fn(WorkspaceEvent)>,
    /// What a structure save's review says about the session's engine.
    pub engine: EngineProfile,
}

/// Starts, stops and settles a window's saves, and says what closing
/// any part of it would lose. Clones share one workspace.
#[derive(Clone)]
pub struct WorkspaceHandle(Rc<Inner>);

struct Inner {
    deps: WorkspaceDeps,
    ledger: SaveLedger,
    /// The structure tabs whose save waits on a review.
    reviewing: RefCell<HashSet<Uuid>>,
    /// Work a window close asks about before it closes any tab.
    blockers: RefCell<Vec<Rc<dyn CloseBlocker>>>,
    /// What the close prompt deciding now covers.
    asking: Cell<Option<CloseScope>>,
}

impl Inner {
    /// The tracker has taken the outcome in, so the ledger lets the
    /// save go, which may wake a close waiting on it, and the tab is
    /// told.
    fn settled(&self, id: SaveId, settled: SaveSettled) {
        // Read here: the prompt this wakes can end before the tab hears.
        let in_prompt = self.asking.get().is_some_and(|scope| scope.covers(settled.tab));
        self.ledger.settle(id);
        (self.deps.events)(WorkspaceEvent::SaveSettled {
            settled: Box::new(settled),
            in_prompt,
        });
    }
}

/// Marks a close prompt as deciding until it is dropped.
pub struct PromptClaim {
    inner: Rc<Inner>,
    previous: Option<CloseScope>,
}

impl Drop for PromptClaim {
    fn drop(&mut self) {
        self.inner.asking.set(self.previous);
    }
}

/// A structure tab's place in `Inner::reviewing`, given up however the
/// save ends.
struct ReviewClaim<'a> {
    reviewing: &'a RefCell<HashSet<Uuid>>,
    tab: Uuid,
}

impl<'a> ReviewClaim<'a> {
    fn take(reviewing: &'a RefCell<HashSet<Uuid>>, tab: Uuid) -> Option<Self> {
        let claimed = reviewing.borrow_mut().insert(tab);
        claimed.then(|| Self { reviewing, tab })
    }
}

impl Drop for ReviewClaim<'_> {
    fn drop(&mut self) {
        self.reviewing.borrow_mut().remove(&self.tab);
    }
}

/// What a save's work brings back to the GTK thread.
struct SaveWork {
    written: Result<WriteReport, OperationError>,
    /// The server's answer about a commit whose acknowledgement was lost.
    resolution: Option<Result<CommitResolution, OperationError>>,
    plan: Option<SavePlan>,
}

impl SaveWork {
    fn failed(error: OperationError) -> Self {
        Self {
            written: Err(error),
            resolution: None,
            plan: None,
        }
    }
}

impl WorkspaceHandle {
    pub fn new(deps: WorkspaceDeps) -> Self {
        Self(Rc::new(Inner {
            deps,
            ledger: SaveLedger::new(),
            reviewing: RefCell::default(),
            blockers: RefCell::default(),
            asking: Cell::new(None),
        }))
    }

    /// Count a close prompt over `scope` as deciding until the claim
    /// drops. A save of a tab it covers settles in front of the prompt,
    /// which waited for it and says itself how it went.
    pub fn claim_for_prompt(&self, scope: CloseScope) -> PromptClaim {
        let previous = self.0.asking.replace(Some(scope));
        PromptClaim {
            inner: self.0.clone(),
            previous,
        }
    }

    /// Have every close of the whole window ask about `blocker`'s work
    /// while it runs.
    pub fn register_close_blocker(&self, blocker: Rc<dyn CloseBlocker>) {
        self.0.blockers.borrow_mut().push(blocker);
    }

    /// Stop the work of the blocker `close_step` named. A blocker that
    /// is not there has nothing to stop.
    pub fn stop_blocker(&self, blocker: usize) -> LocalBoxFuture<'static, ()> {
        let blocker = self.0.blockers.borrow().get(blocker).cloned();
        match blocker {
            Some(blocker) => blocker.stop(),
            None => Box::pin(std::future::ready(())),
        }
    }

    pub fn ledger(&self) -> &SaveLedger {
        &self.0.ledger
    }

    /// Save each tab, in order. A structure save that needs the user's
    /// review shows it on `parent` and starts only once they apply it. A
    /// tab with nothing pending, or that is not a table or structure tab,
    /// has nothing to save.
    pub async fn save(&self, parent: &gtk::Widget, tabs: &[Uuid]) -> Vec<SaveStart> {
        let mut starts = Vec::with_capacity(tabs.len());
        for tab in tabs {
            starts.push(self.save_tab(parent, *tab).await);
        }
        starts
    }

    /// Stop the saves `scope` covers. Each settles when its driver
    /// answers the cancel, as rolled back or with an unknown outcome.
    pub fn stop_saves(&self, scope: CloseScope) {
        self.0.ledger.cancel(scope);
    }

    /// Drop the tabs' pending changes, and with them a save whose
    /// outcome was unknown. `reload` has each tab read its table again.
    pub fn discard(&self, tabs: &[Uuid], reload: bool) {
        for tab in tabs {
            if let Some(tracker) = self.0.deps.rows.get(*tab) {
                let _ = tracker.discard();
            }
            if let Some(tracker) = self.0.deps.structures.get(*tab) {
                tracker.clear();
            }
        }
        self.emit(WorkspaceEvent::Discarded {
            tabs: tabs.to_vec(),
            reload,
        });
    }

    /// Every tab closing would lose something in, in tab order. An
    /// editor tab can have both an open transaction and an unsaved file,
    /// and is listed once for each.
    pub fn dirty_tabs(&self) -> Vec<DirtyTab> {
        self.0
            .deps
            .directory
            .tabs()
            .into_iter()
            .flat_map(|entry| {
                let pending = match self.pending_state(entry.id) {
                    PendingState::OutcomeUnknown(cause) => Some(DirtyKind::OutcomeUnknown(cause)),
                    PendingState::Unsaved | PendingState::Saving => Some(DirtyKind::Unsaved),
                    PendingState::Clean if entry.open_transaction => Some(DirtyKind::OpenTransaction),
                    PendingState::Clean => None,
                };
                let file = entry.unsaved_file.then_some(DirtyKind::UnsavedFile);
                [pending, file].into_iter().flatten().map(move |kind| DirtyTab {
                    id: entry.id,
                    title: entry.title.clone(),
                    kind,
                })
            })
            .collect()
    }

    /// What closing `scope` has to settle next. Open transactions the
    /// user already agreed to lose in this close are not asked again.
    pub fn close_step(&self, scope: CloseScope, acknowledged: &HashSet<Uuid>) -> CloseStep {
        if scope == CloseScope::Window {
            let blocked =
                self.0.blockers.borrow().iter().enumerate().find_map(|(blocker, work)| {
                    work.blocking().map(|prompt| CloseStep::StopBlocker { blocker, prompt })
                });
            if let Some(step) = blocked {
                return step;
            }
        }
        let dirty: Vec<DirtyTab> = self
            .dirty_tabs()
            .into_iter()
            .filter(|tab| {
                let agreed_to_lose = matches!(tab.kind, DirtyKind::OpenTransaction | DirtyKind::UnsavedFile);
                !(agreed_to_lose && acknowledged.contains(&tab.id))
            })
            .collect();
        next_close_step(scope, self.0.ledger.in_flight_in(scope), &dirty)
    }

    fn pending_state(&self, tab: Uuid) -> PendingState {
        if let Some(tracker) = self.0.deps.rows.get(tab) {
            return tracker.pending_state();
        }
        self.0
            .deps
            .structures
            .get(tab)
            .map_or(PendingState::Clean, |tracker| tracker.pending_state())
    }

    fn emit(&self, event: WorkspaceEvent) {
        (self.0.deps.events)(event);
    }

    async fn save_tab(&self, parent: &gtk::Widget, tab: Uuid) -> SaveStart {
        if let Some(tracker) = self.0.deps.rows.get(tab) {
            let Some(_claim) = ReviewClaim::take(&self.0.reviewing, tab) else {
                return SaveStart::Rejected(SaveRejection::InReview);
            };
            if let Err(start) = self.confirm_rows(parent, &tracker).await {
                return start;
            }
            return self.save_rows(tab, &tracker);
        }
        if let Some(tracker) = self.0.deps.structures.get(tab) {
            // A close that saves its tabs can ask again while the review is
            // open, and the review on screen is the one to answer.
            let Some(_claim) = ReviewClaim::take(&self.0.reviewing, tab) else {
                return SaveStart::Rejected(SaveRejection::InReview);
            };
            return match self.review_structure(parent, &tracker).await {
                Ok(reviewed) => self.save_structure(tab, &tracker, reviewed),
                Err(start) => start,
            };
        }
        match self.0.deps.directory.save_file(tab) {
            Some(saving) => match saving.await {
                Ok(()) => SaveStart::Saved,
                Err(message) => SaveStart::Rejected(SaveRejection::FileNotSaved(message)),
            },
            None => SaveStart::NothingToSave,
        }
    }

    /// On a connection that asks before every write, the row save's SQL
    /// is shown first. What is saved has to be what was shown: the tab
    /// can change while the question is open.
    async fn confirm_rows(&self, parent: &gtk::Widget, tracker: &TabTrackerHandle) -> Result<(), SaveStart> {
        let Some(session) = self
            .0
            .deps
            .session
            .get()
            .filter(|session| session.safe_mode() == SafeModeLevel::ConfirmWrites)
        else {
            return Ok(());
        };
        let Some((table, shown)) = row_statements(&session, tracker)? else {
            return Ok(());
        };
        let confirmation = WriteConfirmation::row_save(&session.metadata().name, &table, &shown);
        if !write_confirmation::confirm(parent, &confirmation).await {
            return Err(SaveStart::Rejected(SaveRejection::ReviewDeclined));
        }
        match row_statements(&session, tracker)? {
            Some((_, now)) if same_statements(&now, &shown) => Ok(()),
            _ => Err(SaveStart::Rejected(SaveRejection::ChangedDuringReview)),
        }
    }

    /// The session to save through, refused before anything is taken
    /// from the tracker when it cannot write.
    fn writable_session(&self, state: PendingState) -> Result<Option<Arc<Session>>, SaveRejection> {
        match state {
            PendingState::Clean => return Ok(None),
            PendingState::OutcomeUnknown(_) => return Err(SaveRejection::OutcomeUnknown),
            PendingState::Saving => return Err(SaveRejection::AlreadySaving),
            PendingState::Unsaved => {}
        }
        let session = self.0.deps.session.get().ok_or(SaveRejection::NoConnection)?;
        if session.read_only() {
            return Err(SaveRejection::ReadOnly);
        }
        Ok(Some(session))
    }

    /// Take what `tab` saves from its tracker, with a ledger entry held
    /// for as long as the save runs.
    fn begin<T>(
        &self,
        tab: Uuid,
        kind: WriteKind,
        state: PendingState,
        take: impl FnOnce() -> Result<Option<T>, SaveRejection>,
    ) -> Result<(Arc<Session>, SaveTicket, T), SaveStart> {
        let session = match self.writable_session(state) {
            Ok(Some(session)) => session,
            Ok(None) => return Err(SaveStart::NothingToSave),
            Err(rejection) => return Err(SaveStart::Rejected(rejection)),
        };
        let Some(ticket) = self.0.ledger.begin(&*self.0.deps.hold, tab, kind) else {
            return Err(SaveStart::Rejected(SaveRejection::AlreadySaving));
        };
        let taken = match take() {
            Ok(Some(taken)) => taken,
            Ok(None) => {
                self.0.ledger.settle(ticket.id);
                return Err(SaveStart::NothingToSave);
            }
            Err(rejection) => {
                self.0.ledger.settle(ticket.id);
                return Err(SaveStart::Rejected(rejection));
            }
        };
        self.emit(WorkspaceEvent::SaveStarted { tab });
        Ok((session, ticket, taken))
    }

    fn save_rows(&self, tab: Uuid, tracker: &TabTrackerHandle) -> SaveStart {
        let (session, ticket, batch) = match self.begin(tab, WriteKind::RowChanges, tracker.pending_state(), || {
            tracker.begin_save()
        }) {
            Ok(begun) => begun,
            Err(start) => return start,
        };
        let history = self.history_entry(&session);
        let cancel = ticket.cancel.clone();
        let (table, columns, change_set) = (batch.table, batch.columns, batch.changes.changes.clone());
        let work = async move {
            let planned = session
                .run_cancellable(
                    OperationKind::Save(WriteKind::RowChanges),
                    &cancel,
                    move |lease, options| {
                        let (table, columns, changes) = (table.clone(), columns.clone(), change_set.clone());
                        async move {
                            let plan =
                                plan_save(&*lease.dialect(), &table, &columns, &pk_identity(&columns), &changes)?;
                            let written = lease.write_batch(&plan.batch, options).await;
                            Ok((plan, written))
                        }
                    },
                )
                .await;
            let (plan, written) = match planned {
                Ok((plan, written)) => (Some(plan), written.map_err(OperationError::from)),
                Err(error) => (None, Err(error)),
            };
            let resolution = resolve_commit(&session, &written).await;
            let statements: Vec<String> = plan
                .iter()
                .flat_map(|plan| plan.batch.steps.iter().map(|step| step.statement.sql().to_owned()))
                .collect();
            record(history, statements, &written, resolution.as_ref()).await;
            SaveWork {
                written,
                resolution,
                plan,
            }
        };

        let inner = self.0.clone();
        let tracker = tracker.clone();
        let (changes, snapshot, id) = (batch.changes, batch.snapshot, ticket.id);
        let origins = ChangeOrigins::of(&changes.changes);
        let _delivery = crate::runtime::spawn_and_deliver(&self.0.deps.tasks, work, move |finished| {
            let work = finished.unwrap_or_else(|failure| SaveWork::failed(OperationError::from(failure)));
            let failing = failing_step(&work, &changes);
            let outcome = outcome_of(work.written, work.resolution);
            let _settled = tracker.settle_save(&outcome, snapshot);
            inner.settled(
                id,
                SaveSettled {
                    tab,
                    kind: WriteKind::RowChanges,
                    outcome,
                    failing,
                    saved_table_name: None,
                    origins,
                },
            );
        });
        SaveStart::Started(id)
    }

    /// What the structure save would run, agreed to by the user where it
    /// loses something or can stop halfway. Nothing is taken from the
    /// tracker yet.
    async fn review_structure(
        &self,
        parent: &gtk::Widget,
        tracker: &StructureTrackerHandle,
    ) -> Result<ChangeReview, SaveStart> {
        let (table, review) = self.plan_review(tracker)?;
        let engine = &self.0.deps.engine;
        let asks_first = self
            .0
            .deps
            .session
            .get()
            .filter(|session| session.safe_mode() == SafeModeLevel::ConfirmWrites)
            .map(|session| session.metadata().name.clone());
        if asks_first.is_some() || review.requires_confirmation(engine.ddl_writes) {
            if review_dialog::confirm(parent, &table, &review, engine, asks_first.as_deref()).await
                == ReviewDecision::Cancel
            {
                return Err(SaveStart::Rejected(SaveRejection::ReviewDeclined));
            }
            // The draft and the connection can still change while the
            // review is open.
            let (_, now) = self.plan_review(tracker)?;
            if now.statements != review.statements {
                return Err(SaveStart::Rejected(SaveRejection::Unplannable(
                    BuildDdlError::NotAsReviewed,
                )));
            }
        }
        Ok(review)
    }

    /// The structure save planned with the session's dialect, and the
    /// name of its table.
    fn plan_review(&self, tracker: &StructureTrackerHandle) -> Result<(String, ChangeReview), SaveStart> {
        let session = match self.writable_session(tracker.pending_state()) {
            Ok(Some(session)) => session,
            Ok(None) => return Err(SaveStart::NothingToSave),
            Err(rejection) => return Err(SaveStart::Rejected(rejection)),
        };
        let pending = match tracker.pending_save() {
            Ok(Some(pending)) => pending,
            Ok(None) => return Err(SaveStart::NothingToSave),
            Err(rejection) => return Err(SaveStart::Rejected(rejection)),
        };
        let dialect = session
            .current_dialect()
            .ok_or(SaveStart::Rejected(SaveRejection::NoConnection))?;
        let review = dialect
            .ddl()
            .ok_or(BuildDdlError::Unsupported(pending.operation()))
            .and_then(|ddl| pending.review(ddl))
            .map_err(|error| SaveStart::Rejected(SaveRejection::Unplannable(error)))?;
        Ok((pending.table().name, review))
    }

    /// Runs only the statements reviewed: a connection replaced since the
    /// review plans others, and the save is refused before anything is
    /// sent.
    fn save_structure(&self, tab: Uuid, tracker: &StructureTrackerHandle, reviewed: ChangeReview) -> SaveStart {
        let (session, ticket, pending) =
            match self.begin(tab, WriteKind::SchemaChanges, tracker.pending_state(), || {
                tracker.begin_save()
            }) {
                Ok(begun) => begun,
                Err(start) => return start,
            };
        let history = self.history_entry(&session);
        let cancel = ticket.cancel.clone();
        let saved_table_name = pending.saved_table_name();
        let (table, operation) = (pending.table(), pending.operation());
        let work = async move {
            let planned = run_schema_plan(session.clone(), table, operation, &cancel, move |ddl, _| {
                let plan = pending.plan(ddl)?;
                match reviewed.matches(&plan) {
                    true => Ok(plan),
                    false => Err(BuildDdlError::NotAsReviewed),
                }
            })
            .await;
            let (statements, written) = planned.unwrap_or_else(|error| (Vec::new(), Err(error)));
            let resolution = resolve_commit(&session, &written).await;
            record(history, statements, &written, resolution.as_ref()).await;
            SaveWork {
                written,
                resolution,
                plan: None,
            }
        };

        let inner = self.0.clone();
        let tracker = tracker.clone();
        let id = ticket.id;
        let _delivery = crate::runtime::spawn_and_deliver(&self.0.deps.tasks, work, move |finished| {
            let work = finished.unwrap_or_else(|failure| SaveWork::failed(OperationError::from(failure)));
            let outcome = outcome_of(work.written, work.resolution);
            tracker.settle_save(&outcome);
            inner.settled(
                id,
                SaveSettled {
                    tab,
                    kind: WriteKind::SchemaChanges,
                    outcome,
                    failing: None,
                    saved_table_name,
                    origins: ChangeOrigins::default(),
                },
            );
        });
        SaveStart::Started(id)
    }

    /// Captured before the work starts: the connection may be gone by
    /// the time the answer comes back.
    fn history_entry(&self, session: &Session) -> HistoryEntry {
        HistoryEntry {
            history: self.0.deps.history.clone(),
            connection: Some(session.metadata().clone()),
            dialect: session.current_dialect(),
        }
    }
}

impl std::fmt::Debug for WorkspaceHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkspaceHandle")
            .field("ledger", &self.0.ledger)
            .finish_non_exhaustive()
    }
}

/// The table a row save writes to and its statements with their values,
/// planned with the session's dialect, without taking the changes from
/// the tab.
fn row_statements(
    session: &Session,
    tracker: &TabTrackerHandle,
) -> Result<Option<(String, Vec<Statement>)>, SaveStart> {
    let Some((target, changes)) = tracker.preview_save().map_err(SaveStart::Rejected)? else {
        return Ok(None);
    };
    let dialect = session
        .current_dialect()
        .ok_or(SaveStart::Rejected(SaveRejection::NoConnection))?;
    let columns = &target.columns;
    let plan = plan_save(
        &*dialect,
        &target.table,
        columns,
        &pk_identity(columns),
        &changes.changes,
    )
    .map_err(|error| SaveStart::Rejected(SaveRejection::Build(error)))?;
    let statements = plan.batch.steps.into_iter().map(|step| step.statement).collect();
    Ok(Some((target.table.name, statements)))
}

/// Statement by statement, the same SQL binding the same values. A NaN
/// is the same NaN, which `==` on floats would deny.
fn same_statements(left: &[Statement], right: &[Statement]) -> bool {
    left.len() == right.len()
        && left.iter().zip(right).all(|(left, right)| {
            left.sql() == right.sql()
                && left.params().len() == right.params().len()
                && left.params().iter().zip(right.params()).all(|(left, right)| {
                    left.param_type() == right.param_type() && same_value(left.value(), right.value())
                })
        })
}

struct HistoryEntry {
    history: Option<HistoryService>,
    connection: Option<tablepro_session::ConnectionMetadata>,
    dialect: Option<std::sync::Arc<dyn tablepro_core::dialect::SqlDialect>>,
}

/// A save changes the database as surely as a statement typed into the
/// editor, so it goes in the same history. A history that cannot be
/// written is worth a log line, never a lost save.
async fn record(
    entry: HistoryEntry,
    statements: Vec<String>,
    written: &Result<WriteReport, OperationError>,
    resolution: Option<&Result<CommitResolution, OperationError>>,
) {
    let ran = RanStatements::starting(entry.history, entry.connection, entry.dialect, statements);
    let (rows, outcome) = match (written, resolution) {
        (Ok(report), _) => (
            report.total_rows().and_then(|rows| i64::try_from(rows).ok()),
            Outcome::Success,
        ),
        (Err(_), Some(Ok(CommitResolution::Applied))) => (None, Outcome::Success),
        (Err(error), _) => (
            None,
            Outcome::Error(crate::ui::error_text::operation_error_message(error)),
        ),
    };
    ran.finished(rows, outcome).await;
}

/// Ask the server what became of a commit whose acknowledgement was
/// lost, when the engine left a way to ask.
async fn resolve_commit(
    session: &Session,
    written: &Result<WriteReport, OperationError>,
) -> Option<Result<CommitResolution, OperationError>> {
    let Err(OperationError::Driver(DriverError::CommitOutcomeUnknown { token: Some(token), .. })) = written else {
        return None;
    };
    let token = token.clone();
    let resolved = session
        .run(OperationKind::Metadata, move |lease, options| {
            let token = token.clone();
            async move {
                lease
                    .resolve_commit(&token, options)
                    .await
                    .map_err(OperationError::from)
            }
        })
        .await;
    if let Err(error) = &resolved {
        tracing::warn!(%error, "could not ask the server whether a save landed");
    }
    Some(resolved)
}

/// The outcome once the server has answered for a lost acknowledgement.
/// An answer that is not final, or no answer, leaves it unknown.
fn outcome_of(
    written: Result<WriteReport, OperationError>,
    resolution: Option<Result<CommitResolution, OperationError>>,
) -> SaveOutcome {
    let outcome = SaveOutcome::classify(written);
    let SaveOutcome::Unknown(UnknownCause::CommitAckLost { .. }) = &outcome else {
        return outcome;
    };
    match resolution {
        Some(Ok(CommitResolution::Applied)) => SaveOutcome::Committed { rows: None },
        Some(Ok(CommitResolution::NotApplied)) => SaveOutcome::RolledBack(RollbackCause::NotApplied),
        Some(Ok(CommitResolution::PartiallyApplied)) => SaveOutcome::Unknown(UnknownCause::PartiallyApplied),
        _ => outcome,
    }
}

/// The grid row behind the statement a row save stopped at, when the
/// engine said which one it was.
fn failing_step(work: &SaveWork, changes: &TrackedChanges) -> Option<StatementSource> {
    let (Some(plan), Err(OperationError::Driver(error))) = (&work.plan, &work.written) else {
        return None;
    };
    failing_source(plan, changes, error)
}

fn failing_source(plan: &SavePlan, changes: &TrackedChanges, error: &DriverError) -> Option<StatementSource> {
    let step = match error {
        DriverError::RolledBack { statement_index, .. }
        | DriverError::RowGuardFailed { statement_index, .. }
        | DriverError::GuardUnsupported { statement_index }
        | DriverError::PartiallyApplied { statement_index, .. } => *statement_index,
        _ => return None,
    };
    changes.source(plan.origin(step)?)
}

#[cfg(test)]
mod tests {
    use tablepro_core::edit::CellInput;
    use tablepro_core::meta::TableRef;
    use tablepro_core::{BusyReason, CommitToken, LossPhase, Value};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

    use super::*;
    use crate::services::change_tracker::RowKey;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::wait_until;
    use crate::workspace::test_workspace::{WAIT, Workspace, integer, sqlite};

    fn commit_ack_lost(resolution: Result<CommitResolution, DriverError>) -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::err(DriverError::CommitOutcomeUnknown {
                token: Some(CommitToken::PostgresXid {
                    xid: 812,
                    legacy_txid: false,
                }),
                source: Box::new(DriverError::ConnectionLost {
                    during: LossPhase::Commit,
                }),
            }));
        script.resolve_commit.always(FakeReply::Ready(resolution));
        script
    }

    #[gtk4::test]
    fn commit_ack_lost_applied_reloads() {
        let workspace = Workspace::open(commit_ack_lost(Ok(CommitResolution::Applied)));

        let settled = workspace.save();

        assert_eq!(settled.outcome, SaveOutcome::Committed { rows: None });
        assert_eq!(CallCounters::get(&workspace.counters().resolve_commit), 1);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
        assert_eq!(workspace.handle.ledger().in_flight(), 0);
        assert_eq!(workspace.hold.live(), 0, "the settled save still held the process");
    }

    #[gtk4::test]
    fn not_applied_rolls_back() {
        let workspace = Workspace::open(commit_ack_lost(Ok(CommitResolution::NotApplied)));

        let settled = workspace.save();

        assert_eq!(settled.outcome, SaveOutcome::RolledBack(RollbackCause::NotApplied));
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert!(matches!(workspace.start().as_slice(), [SaveStart::Started(_)]));
        workspace.settle();
    }

    #[gtk4::test]
    fn unresolvable_freezes() {
        for resolution in [
            Ok(CommitResolution::Unresolvable),
            Ok(CommitResolution::StillRunning),
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            }),
        ] {
            let workspace = Workspace::open(commit_ack_lost(resolution.clone()));

            let settled = workspace.save();

            assert!(
                matches!(
                    settled.outcome,
                    SaveOutcome::Unknown(UnknownCause::CommitAckLost { token: Some(_) })
                ),
                "{resolution:?}: {:?}",
                settled.outcome
            );
            assert!(matches!(
                workspace.tracker.pending_state(),
                PendingState::OutcomeUnknown(_)
            ));
            assert_eq!(workspace.start(), [SaveStart::Rejected(SaveRejection::OutcomeUnknown)]);
            assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
            assert!(matches!(
                workspace.handle.dirty_tabs().as_slice(),
                [DirtyTab {
                    kind: DirtyKind::OutcomeUnknown(_),
                    ..
                }]
            ));
        }
    }

    #[gtk4::test]
    fn stop_saves_cancels_write_batch_token() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::StoppedWith(Err(DriverError::RolledBack {
                statement_index: 0,
                source: Box::new(DriverError::Cancelled),
            })));
        let workspace = Workspace::open(script);
        let started = workspace.start();
        assert!(matches!(started.as_slice(), [SaveStart::Started(_)]));
        wait_until(WAIT, || {
            !workspace.fake.connection.observed_cancels("write_batch").is_empty()
        })
        .expect("the write to start");
        let observed = workspace.fake.connection.observed_cancels("write_batch");
        assert!(!observed[0].is_cancelled());
        assert_eq!(workspace.hold.live(), 1);

        workspace.handle.stop_saves(CloseScope::Tab(workspace.tab));
        let settled = workspace.settle();

        assert!(observed[0].is_cancelled(), "the write never saw the stop");
        assert!(matches!(settled.outcome, SaveOutcome::RolledBack(_)));
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert_eq!(workspace.handle.ledger().in_flight(), 0);
    }

    #[gtk4::test]
    fn a_save_settles_under_a_prompt_only_while_one_covers_its_tab() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::ok(WriteReport::new(vec![Some(1)])));
        let workspace = Workspace::open(script);
        let edits = Cell::new(10);
        let save_under = |scope: Option<CloseScope>| {
            let _claim = scope.map(|scope| workspace.handle.claim_for_prompt(scope));
            edits.set(edits.get() + 1);
            workspace.edit(edits.get());
            workspace.save();
            workspace.settled_in_prompt().pop().expect("a settled save")
        };

        assert!(!save_under(None));
        assert!(
            !save_under(Some(CloseScope::Tab(Uuid::new_v4()))),
            "another tab's prompt took the save"
        );
        assert!(save_under(Some(CloseScope::Tab(workspace.tab))));
        assert!(save_under(Some(CloseScope::Window)));
        let window = workspace.handle.claim_for_prompt(CloseScope::Window);
        drop(workspace.handle.claim_for_prompt(CloseScope::Tab(Uuid::new_v4())));
        assert!(save_under(None), "an inner claim ended the outer one");
        drop(window);
        assert!(!save_under(None), "a prompt that ended still took the save");
    }

    #[gtk4::test]
    fn a_read_only_connection_refuses_before_taking_the_changes() {
        let workspace = Workspace::open(ConnectionScript {
            read_only: true,
            ..ConnectionScript::default()
        });

        assert_eq!(workspace.start(), [SaveStart::Rejected(SaveRejection::ReadOnly)]);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert_eq!(workspace.handle.ledger().in_flight(), 0);
    }

    fn planned() -> (SavePlan, TrackedChanges, RowKey) {
        let columns = vec![integer("id", true), integer("n", false)];
        let edited = RowKey::from_pk_values(&[Value::Int(3)]).unwrap();
        let tracker = TabTrackerHandle::default();
        let _ = tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![
                vec![Value::Int(10), Value::Int(1)]
                    .into_iter()
                    .map(CellInput::Value)
                    .collect(),
            ],
        });
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: edited.clone(),
            col: 1,
            original: Value::Int(1),
            value: Value::Int(2),
        });
        let changes = tracker.change_set(&columns).unwrap();
        let plan = plan_save(
            &*sqlite(),
            &TableRef::unqualified("t"),
            &columns,
            &pk_identity(&columns),
            &changes.changes,
        )
        .unwrap();
        (plan, changes, edited)
    }

    #[test]
    fn a_guard_failure_flashes_the_row_it_was_about() {
        let (plan, changes, edited) = planned();
        let error = DriverError::RowGuardFailed {
            statement_index: 1,
            expected: 1,
            actual: 0,
        };

        let source = failing_source(&plan, &changes, &error);

        assert!(matches!(source, Some(StatementSource::Update { row_key }) if row_key == edited));
    }

    #[test]
    fn a_rolled_back_insert_flashes_its_draft() {
        let (plan, changes, _) = planned();
        let error = DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(DriverError::server("duplicate key")),
        };

        assert!(matches!(
            failing_source(&plan, &changes, &error),
            Some(StatementSource::Insert { .. })
        ));
    }

    #[test]
    fn an_error_that_names_no_statement_flashes_nothing() {
        let (plan, changes, _) = planned();

        assert!(failing_source(&plan, &changes, &DriverError::Busy(BusyReason::NoFreeConnection)).is_none());
        let past_the_end = DriverError::RowGuardFailed {
            statement_index: 7,
            expected: 1,
            actual: 0,
        };
        assert!(failing_source(&plan, &changes, &past_the_end).is_none());
    }
}
