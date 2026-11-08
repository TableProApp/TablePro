use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use uuid::Uuid;

use super::{CloseDecision, CloseGuard, CloseScope, CloseStep, WorkspaceHandle};

type CloseWaiter = Box<dyn FnOnce(CloseDecision)>;
pub(crate) type WindowPreflight = Rc<dyn Fn(&gtk::Window) -> LocalBoxFuture<'static, CloseDecision>>;
type WindowHandles = Rc<dyn Fn() -> Vec<WorkspaceHandle>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowClose {
    Open,
    Asking,
    Approved,
}

pub(crate) struct CloseGuards {
    turn: futures::lock::Mutex<()>,
    window: Cell<WindowClose>,
    requests: Cell<u64>,
    waiting: RefCell<Vec<CloseWaiter>>,
    preflight: RefCell<Option<Rc<dyn Fn() -> WindowPreflight>>>,
    teardown_acknowledged: RefCell<HashSet<Uuid>>,
}

impl CloseGuards {
    pub(crate) fn new() -> Rc<Self> {
        Rc::new(Self {
            turn: futures::lock::Mutex::new(()),
            window: Cell::new(WindowClose::Open),
            requests: Cell::new(0),
            waiting: RefCell::new(Vec::new()),
            preflight: RefCell::new(None),
            teardown_acknowledged: RefCell::new(HashSet::new()),
        })
    }

    pub(crate) fn set_window_preflight(&self, preflight: impl Fn() -> WindowPreflight + 'static) {
        self.preflight.replace(Some(Rc::new(preflight)));
    }

    async fn run(
        &self,
        parent: &gtk::Widget,
        handles: &[WorkspaceHandle],
        scope: CloseScope,
        acknowledged: &mut HashSet<Uuid>,
    ) -> CloseDecision {
        let _turn = self.turn.lock().await;
        CloseGuard::run(parent, handles, scope, acknowledged).await
    }

    pub(crate) fn connect_window<W: IsA<gtk::Window>>(
        self: &Rc<Self>,
        window: &W,
        handles: impl Fn() -> Vec<WorkspaceHandle> + 'static,
        on_close: impl Fn(&W) + 'static,
    ) {
        let guards = self.clone();
        let handles: WindowHandles = Rc::new(handles);
        window.connect_close_request(move |window| {
            guards.requests.set(guards.requests.get() + 1);
            if !guards.window_may_close(window.upcast_ref(), handles.clone()) {
                return glib::Propagation::Stop;
            }
            on_close(window);
            guards.settle(CloseDecision::Approved);
            glib::Propagation::Proceed
        });
    }

    pub(crate) fn request_window_close(
        &self,
        window: &impl IsA<gtk::Window>,
        decided: impl FnOnce(CloseDecision) + 'static,
    ) {
        self.waiting.borrow_mut().push(Box::new(decided));
        if self.window.get() == WindowClose::Asking {
            return;
        }
        let before = self.requests.get();
        window.close();
        if self.requests.get() == before {
            // libadwaita takes a close request over one of its dialogs as
            // dismissing the dialog, and the window stays open.
            self.settle(CloseDecision::Cancelled);
        }
    }

    fn settle(&self, decision: CloseDecision) {
        let waiting = self.waiting.take();
        for decided in waiting {
            decided(decision);
        }
    }

    fn window_may_close(self: &Rc<Self>, window: &gtk::Window, handles: WindowHandles) -> bool {
        match self.window.get() {
            WindowClose::Asking => return false,
            WindowClose::Approved => return true,
            WindowClose::Open => {}
        }
        let preflight = self.preflight.borrow().clone();
        if preflight.is_none()
            && handles()
                .iter()
                .all(|handle| handle.close_step(CloseScope::Window, &HashSet::new()) == CloseStep::Approve)
        {
            return true;
        }
        self.window.set(WindowClose::Asking);
        let (guards, window) = (self.clone(), window.clone());
        glib::spawn_future_local(async move {
            let decision = {
                let _turn = guards.turn.lock().await;
                let preflight = preflight.map(|make| make());
                let mut acknowledged = HashSet::new();
                let ready = match &preflight {
                    Some(preflight) => preflight(&window).await,
                    None => CloseDecision::Approved,
                };
                if ready == CloseDecision::Approved {
                    loop {
                        if CloseGuard::run(window.upcast_ref(), &handles(), CloseScope::Window, &mut acknowledged).await
                            == CloseDecision::Cancelled
                        {
                            break CloseDecision::Cancelled;
                        }
                        if let Some(preflight) = &preflight
                            && preflight(&window).await == CloseDecision::Cancelled
                        {
                            break CloseDecision::Cancelled;
                        }
                        if handles()
                            .iter()
                            .all(|handle| handle.close_step(CloseScope::Window, &acknowledged) == CloseStep::Approve)
                        {
                            break CloseDecision::Approved;
                        }
                    }
                } else {
                    CloseDecision::Cancelled
                }
            };
            match decision {
                CloseDecision::Approved => {
                    guards.window.set(WindowClose::Approved);
                    window.close();
                }
                CloseDecision::Cancelled => {
                    guards.window.set(WindowClose::Open);
                    guards.settle(CloseDecision::Cancelled);
                }
            }
        });
        false
    }

    pub(crate) fn may_close_tab(&self, handle: &WorkspaceHandle, tab: Uuid) -> bool {
        handle.close_step(CloseScope::Tab(tab), &HashSet::new()) == CloseStep::Approve
    }

    pub(crate) fn ask_close_tab(
        self: &Rc<Self>,
        parent: &gtk::Widget,
        handle: &WorkspaceHandle,
        tab: Uuid,
        decided: impl FnOnce(CloseDecision) + 'static,
    ) {
        let (guards, handle, parent) = (self.clone(), handle.clone(), parent.clone());
        glib::spawn_future_local(async move {
            let decision = guards
                .run(
                    &parent,
                    std::slice::from_ref(&handle),
                    CloseScope::Tab(tab),
                    &mut HashSet::new(),
                )
                .await;
            decided(decision);
        });
    }

    pub(crate) fn begin_teardown(&self) {
        self.teardown_acknowledged.borrow_mut().clear();
    }

    pub(crate) fn may_tear_down(&self, handles: &[WorkspaceHandle]) -> bool {
        let acknowledged = self.teardown_acknowledged.borrow();
        handles
            .iter()
            .all(|handle| handle.close_step(CloseScope::Window, &acknowledged) == CloseStep::Approve)
    }

    pub(crate) fn ask_tear_down(
        self: &Rc<Self>,
        parent: &gtk::Widget,
        handles: &[WorkspaceHandle],
        decided: impl FnOnce(CloseDecision) + 'static,
    ) {
        let (guards, handles, parent) = (self.clone(), handles.to_vec(), parent.clone());
        glib::spawn_future_local(async move {
            let mut acknowledged = guards.teardown_acknowledged.borrow().clone();
            let decision = guards
                .run(&parent, &handles, CloseScope::Window, &mut acknowledged)
                .await;
            if decision == CloseDecision::Approved {
                guards.teardown_acknowledged.replace(acknowledged);
            }
            decided(decision);
        });
    }
}

#[cfg(test)]
mod tests {
    use libadwaita as adw;
    use libadwaita::prelude::*;
    use tablepro_core::Value;
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::services::change_tracker::RowKey;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{OwnedWindow, drain_main_context, wait_until};
    use crate::workspace::PendingState;
    use crate::workspace::dialog_response::{answer, visible_alert};
    use crate::workspace::test_workspace::{WAIT, Workspace};

    fn window() -> OwnedWindow<adw::Window> {
        adw::init().expect("libadwaita initialises under the test backend");
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        OwnedWindow::presented(adw::Window::new())
    }

    fn guarded_window(guards: &Rc<CloseGuards>, workspace: &Workspace) -> (OwnedWindow<adw::Window>, Rc<Cell<usize>>) {
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        let handle = workspace.handle.clone();
        guards.connect_window(
            &*window,
            move || vec![handle.clone()],
            move |_| sink.set(sink.get() + 1),
        );
        (window, closes)
    }

    fn answer_next(
        window: &adw::Window,
        heading: &str,
        response: &str,
        seen: Option<&adw::AlertDialog>,
    ) -> adw::AlertDialog {
        let mut shown = None;
        wait_until(WAIT, || {
            shown = visible_alert(window)
                .filter(|alert| alert.heading().as_deref() == Some(heading) && Some(alert) != seen);
            shown.is_some()
        })
        .unwrap_or_else(|_| panic!("no “{heading}” alert"));
        assert!(answer(window, response));
        shown.expect("the alert")
    }

    fn edit_again(workspace: &Workspace) {
        let _ = workspace.tracker.apply(TrackerEdit::Cell {
            row_key: RowKey::from_pk_values(&[Value::Int(2)]).expect("a key"),
            col: 1,
            original: Value::Int(1),
            value: tablepro_core::edit::CellInput::Value(Value::Int(7)),
        });
    }

    fn decision_sink() -> (Rc<Cell<Option<CloseDecision>>>, impl FnOnce(CloseDecision) + 'static) {
        let decision = Rc::new(Cell::new(None));
        let sink = decision.clone();
        (decision, move |decided| sink.set(Some(decided)))
    }

    #[gtk4::test]
    fn a_clean_window_closes_without_asking() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.handle.discard(&[workspace.tab], false);
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);

        window.close();

        assert_eq!(closes.get(), 1);
        assert!(visible_alert(&window).is_none());
    }

    #[gtk4::test]
    fn one_save_changes_covers_every_workspace_and_cancel_keeps_them_all() {
        let (first, second) = (
            Workspace::open(ConnectionScript::default()),
            Workspace::open(ConnectionScript::default()),
        );
        let guards = CloseGuards::new();
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        let handles = [first.handle.clone(), second.handle.clone()];
        guards.connect_window(&*window, move || handles.to_vec(), move |_| sink.set(sink.get() + 1));

        window.close();
        let kept = answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || guards.window.get() == WindowClose::Open).expect("the close to be dropped");

        assert_eq!(
            kept.response_label("discard").as_str(),
            "_Discard All",
            "the prompt did not list both tabs"
        );
        assert_eq!(closes.get(), 0);
        assert_eq!(first.tracker.pending_state(), PendingState::Unsaved);
        assert_eq!(second.tracker.pending_state(), PendingState::Unsaved);

        window.close();
        answer_next(&window, "Save Changes?", "discard", Some(&kept));
        wait_until(WAIT, || closes.get() == 1).expect("the approved close to go through");
        drain_main_context();

        assert_eq!(closes.get(), 1);
        assert_eq!(first.tracker.pending_state(), PendingState::Clean);
        assert_eq!(second.tracker.pending_state(), PendingState::Clean);
    }

    #[gtk4::test]
    fn a_window_with_no_workspace_closes_without_asking() {
        let guards = CloseGuards::new();
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(&*window, Vec::new, move |_| sink.set(sink.get() + 1));

        window.close();

        assert_eq!(closes.get(), 1);
        assert!(visible_alert(&window).is_none());
    }

    #[gtk4::test]
    fn a_preflight_holds_an_empty_window_and_joins_close_requests() {
        let guards = CloseGuards::new();
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(&*window, Vec::new, move |_| sink.set(sink.get() + 1));
        let (send, receive) = futures::channel::oneshot::channel();
        let receive = Rc::new(RefCell::new(Some(receive)));
        let calls = Rc::new(Cell::new(0));
        let observed = calls.clone();
        let attempts = Rc::new(Cell::new(0));
        let made = attempts.clone();
        guards.set_window_preflight(move || {
            made.set(made.get() + 1);
            let (observed, receive) = (observed.clone(), receive.clone());
            Rc::new(move |_| {
                observed.set(observed.get() + 1);
                let receive = receive.borrow_mut().take();
                Box::pin(async move {
                    match receive {
                        Some(receive) => receive.await.expect("preflight answer"),
                        None => CloseDecision::Approved,
                    }
                })
            })
        });
        let (first, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        let (second, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        drain_main_context();
        assert_eq!(calls.get(), 1);
        assert_eq!(closes.get(), 0);
        assert_eq!(first.get(), None);
        assert_eq!(second.get(), None);
        assert!(window.is_visible());

        send.send(CloseDecision::Approved).expect("waiting preflight");
        wait_until(WAIT, || closes.get() == 1).expect("approved close");
        assert_eq!(first.get(), Some(CloseDecision::Approved));
        assert_eq!(second.get(), Some(CloseDecision::Approved));
        assert_eq!(calls.get(), 2);
        assert_eq!(attempts.get(), 1);
    }

    #[gtk4::test]
    fn a_cancelled_preflight_keeps_the_window_and_can_be_asked_again() {
        let guards = CloseGuards::new();
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(&*window, Vec::new, move |_| sink.set(sink.get() + 1));
        let calls = Rc::new(Cell::new(0));
        let observed = calls.clone();
        guards.set_window_preflight(move || {
            let observed = observed.clone();
            Rc::new(move |_| {
                let call = observed.get();
                observed.set(call + 1);
                Box::pin(std::future::ready(if call == 0 {
                    CloseDecision::Cancelled
                } else {
                    CloseDecision::Approved
                }))
            })
        });
        let (cancelled, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        wait_until(WAIT, || cancelled.get().is_some()).expect("cancelled close");
        assert_eq!(cancelled.get(), Some(CloseDecision::Cancelled));
        assert_eq!(guards.window.get(), WindowClose::Open);
        assert_eq!(closes.get(), 0);
        assert!(window.is_visible());

        let (approved, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        wait_until(WAIT, || approved.get().is_some()).expect("second close");
        assert_eq!(approved.get(), Some(CloseDecision::Approved));
        assert_eq!(calls.get(), 3);
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn a_cancelled_preflight_does_not_discard_workspace_changes() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);
        guards.set_window_preflight(|| Rc::new(|_| Box::pin(std::future::ready(CloseDecision::Cancelled))));
        let (decision, sink) = decision_sink();

        guards.request_window_close(&*window, sink);
        wait_until(WAIT, || decision.get().is_some()).expect("preflight decision");

        assert_eq!(decision.get(), Some(CloseDecision::Cancelled));
        assert_eq!(closes.get(), 0);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert!(visible_alert(&window).is_none());
    }

    #[gtk4::test]
    fn workspaces_added_while_preflight_waits_are_asked_before_close() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let window = window();
        let handles = Rc::new(RefCell::new(Vec::new()));
        let current = handles.clone();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(
            &*window,
            move || current.borrow().clone(),
            move |_| sink.set(sink.get() + 1),
        );
        let (send, receive) = futures::channel::oneshot::channel();
        let receive = Rc::new(RefCell::new(Some(receive)));
        guards.set_window_preflight(move || {
            let receive = receive.clone();
            Rc::new(move |_| {
                let receive = receive.borrow_mut().take().expect("one preflight");
                Box::pin(async move { receive.await.expect("preflight answer") })
            })
        });
        window.close();
        drain_main_context();
        handles.borrow_mut().push(workspace.handle.clone());
        send.send(CloseDecision::Approved).expect("waiting preflight");

        answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || guards.window.get() == WindowClose::Open).expect("cancelled close");
        assert_eq!(closes.get(), 0);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
    }

    #[gtk4::test]
    fn a_final_preflight_holds_the_close_and_cancellation_allows_a_new_attempt() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);
        let (send, receive) = futures::channel::oneshot::channel();
        let receive = Rc::new(RefCell::new(Some(receive)));
        let attempts = Rc::new(Cell::new(0));
        let made = attempts.clone();
        let calls = Rc::new(Cell::new(0));
        let observed = calls.clone();
        guards.set_window_preflight(move || {
            made.set(made.get() + 1);
            let (observed, receive) = (observed.clone(), receive.clone());
            Rc::new(move |_| {
                let call = observed.get() + 1;
                observed.set(call);
                let receive = (call == 2).then(|| receive.borrow_mut().take().expect("final gate"));
                Box::pin(async move {
                    match receive {
                        Some(receive) => receive.await.expect("preflight answer"),
                        None => CloseDecision::Approved,
                    }
                })
            })
        });
        let (first, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        answer_next(&window, "Save Changes?", "discard", None);
        wait_until(WAIT, || calls.get() == 2).expect("final preflight");
        let (second, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        assert_eq!(closes.get(), 0);
        assert_eq!(first.get(), None);
        assert_eq!(second.get(), None);
        assert_eq!(attempts.get(), 1);

        send.send(CloseDecision::Cancelled).expect("waiting final gate");
        wait_until(WAIT, || first.get().is_some()).expect("cancelled close");
        assert_eq!(first.get(), Some(CloseDecision::Cancelled));
        assert_eq!(second.get(), Some(CloseDecision::Cancelled));
        assert_eq!(guards.window.get(), WindowClose::Open);
        assert!(window.is_visible());
        assert_eq!(closes.get(), 0);

        let (approved, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        wait_until(WAIT, || approved.get().is_some()).expect("new close attempt");
        assert_eq!(approved.get(), Some(CloseDecision::Approved));
        assert_eq!(attempts.get(), 2);
        assert_eq!(calls.get(), 4);
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn edits_and_sessions_added_during_the_final_preflight_are_asked_without_repeating_transactions() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.open_transaction_tab();
        let added = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let window = window();
        let handles = Rc::new(RefCell::new(vec![workspace.handle.clone()]));
        let current = handles.clone();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(
            &*window,
            move || current.borrow().clone(),
            move |_| sink.set(sink.get() + 1),
        );
        let (send, receive) = futures::channel::oneshot::channel();
        let receive = Rc::new(RefCell::new(Some(receive)));
        let calls = Rc::new(Cell::new(0));
        let observed = calls.clone();
        guards.set_window_preflight(move || {
            let (observed, receive) = (observed.clone(), receive.clone());
            Rc::new(move |_| {
                let call = observed.get() + 1;
                observed.set(call);
                let receive = (call == 2).then(|| receive.borrow_mut().take().expect("final gate"));
                Box::pin(async move {
                    match receive {
                        Some(receive) => receive.await.expect("preflight answer"),
                        None => CloseDecision::Approved,
                    }
                })
            })
        });
        window.close();
        answer_next(&window, "Close With Open Transactions?", "close", None);
        let first = answer_next(&window, "Save Changes?", "discard", None);
        wait_until(WAIT, || calls.get() == 2).expect("final preflight");
        edit_again(&workspace);
        handles.borrow_mut().push(added.handle.clone());
        send.send(CloseDecision::Approved).expect("waiting final gate");

        let second = answer_next(&window, "Save Changes?", "discard", Some(&first));
        assert_eq!(second.response_label("discard").as_str(), "_Discard All");
        wait_until(WAIT, || closes.get() == 1).expect("close after fresh workspace prompts");
        assert_eq!(calls.get(), 3);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
        assert_eq!(added.tracker.pending_state(), PendingState::Clean);
    }

    #[gtk4::test]
    fn a_close_request_over_the_prompt_keeps_the_window() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);

        window.close();
        wait_until(WAIT, || visible_alert(&window).is_some()).expect("the prompt");
        let first = visible_alert(&window);
        window.close();
        wait_until(WAIT, || guards.window.get() == WindowClose::Open).expect("the prompt to be dismissed");

        assert_eq!(closes.get(), 0, "the window closed before the prompt approved");
        assert!(window.is_visible());
        window.close();
        answer_next(&window, "Save Changes?", "discard", first.as_ref());
        wait_until(WAIT, || closes.get() == 1).expect("the approved close to go through");
        drain_main_context();
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn a_kept_window_asks_again_on_the_next_close() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);

        window.close();
        let kept = answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || guards.window.get() == WindowClose::Open).expect("the close to be dropped");
        assert!(window.is_visible() && closes.get() == 0);
        window.close();
        answer_next(&window, "Save Changes?", "discard", Some(&kept));

        wait_until(WAIT, || closes.get() == 1).expect("the approved close to go through");
    }

    #[gtk4::test]
    fn a_requested_close_of_a_clean_window_is_approved_at_once() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.handle.discard(&[workspace.tab], false);
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);
        let (decision, sink) = decision_sink();

        guards.request_window_close(&*window, sink);

        assert_eq!(decision.get(), Some(CloseDecision::Approved));
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn a_requested_close_hears_the_prompts_answer() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);

        let (kept, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        let first = answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || kept.get().is_some()).expect("a decision");
        assert_eq!(kept.get(), Some(CloseDecision::Cancelled));
        assert!(window.is_visible() && closes.get() == 0);

        let (approved, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        answer_next(&window, "Save Changes?", "discard", Some(&first));
        wait_until(WAIT, || approved.get().is_some()).expect("a decision");
        assert_eq!(approved.get(), Some(CloseDecision::Approved));
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn a_request_during_the_prompt_waits_for_its_answer() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);
        window.close();
        wait_until(WAIT, || visible_alert(&window).is_some()).expect("the prompt");
        let shown = visible_alert(&window);

        let (decision, sink) = decision_sink();
        guards.request_window_close(&*window, sink);
        drain_main_context();
        assert_eq!(visible_alert(&window), shown, "the request dismissed the prompt");
        assert_eq!(decision.get(), None);
        answer_next(&window, "Save Changes?", "discard", None);

        wait_until(WAIT, || decision.get().is_some()).expect("a decision");
        assert_eq!(decision.get(), Some(CloseDecision::Approved));
        assert_eq!(closes.get(), 1);
    }

    #[gtk4::test]
    fn a_close_a_dialog_takes_is_reported_cancelled() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.handle.discard(&[workspace.tab], false);
        let guards = CloseGuards::new();
        let (window, closes) = guarded_window(&guards, &workspace);
        let other = adw::AlertDialog::new(Some("Elsewhere"), None);
        other.add_response("close", "Close");
        other.present(Some(&*window));
        wait_until(WAIT, || visible_alert(&window).is_some()).expect("the dialog");

        let (decision, sink) = decision_sink();
        guards.request_window_close(&*window, sink);

        assert_eq!(decision.get(), Some(CloseDecision::Cancelled));
        assert_eq!(closes.get(), 0);
        assert!(window.is_visible());
    }

    #[gtk4::test]
    fn a_teardown_proceeds_only_when_approved() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let window = window();
        let parent = window.clone().upcast::<gtk::Widget>();
        assert!(!guards.may_tear_down(std::slice::from_ref(&workspace.handle)));

        let (kept, sink) = decision_sink();
        guards.ask_tear_down(&parent, std::slice::from_ref(&workspace.handle), sink);
        let first = answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || kept.get().is_some()).expect("a decision");
        assert_eq!(kept.get(), Some(CloseDecision::Cancelled));
        assert!(!guards.may_tear_down(std::slice::from_ref(&workspace.handle)));

        let (approved, sink) = decision_sink();
        guards.ask_tear_down(&parent, std::slice::from_ref(&workspace.handle), sink);
        answer_next(&window, "Save Changes?", "discard", Some(&first));
        wait_until(WAIT, || approved.get().is_some()).expect("a decision");
        assert_eq!(approved.get(), Some(CloseDecision::Approved));
        assert!(guards.may_tear_down(std::slice::from_ref(&workspace.handle)));
    }

    #[gtk4::test]
    fn a_switch_asks_again_only_about_what_changed_while_connecting() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.open_transaction_tab();
        let guards = CloseGuards::new();
        let window = window();
        let parent = window.clone().upcast::<gtk::Widget>();

        guards.begin_teardown();
        let (approved, sink) = decision_sink();
        guards.ask_tear_down(&parent, std::slice::from_ref(&workspace.handle), sink);
        answer_next(&window, "Close With Open Transactions?", "close", None);
        let first = answer_next(&window, "Save Changes?", "discard", None);
        wait_until(WAIT, || approved.get().is_some()).expect("a decision");
        assert!(guards.may_tear_down(std::slice::from_ref(&workspace.handle)));

        edit_again(&workspace);
        assert!(
            !guards.may_tear_down(std::slice::from_ref(&workspace.handle)),
            "an edit made while connecting went unasked"
        );
        let (again, sink) = decision_sink();
        guards.ask_tear_down(&parent, std::slice::from_ref(&workspace.handle), sink);
        answer_next(&window, "Save Changes?", "discard", Some(&first));
        wait_until(WAIT, || again.get().is_some()).expect("a decision");
        assert_eq!(again.get(), Some(CloseDecision::Approved));

        guards.begin_teardown();
        assert!(
            !guards.may_tear_down(std::slice::from_ref(&workspace.handle)),
            "a new switch skipped the transaction"
        );
    }
}
