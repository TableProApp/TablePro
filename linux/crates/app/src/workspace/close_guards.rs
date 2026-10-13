use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use uuid::Uuid;

use super::{CloseDecision, CloseGuard, CloseScope, CloseStep, WorkspaceHandle};

/// Where the window's own close stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowClose {
    Open,
    /// The prompts are deciding.
    Asking,
    /// Nothing is left to lose, so the next close request goes through.
    Approved,
}

/// A window's close prompts. One runs at a time, so a tab's close and
/// the window's never ask about the same tab at once: a second waits for
/// the first, then reads the workspace as the first left it.
pub(crate) struct CloseGuards {
    turn: futures::lock::Mutex<()>,
    window: Cell<WindowClose>,
    /// Open transactions the user agreed to lose in the current
    /// disconnect or switch. A switch asks again once its connection is
    /// ready, about what changed while it connected, but not about these.
    teardown_acknowledged: RefCell<HashSet<Uuid>>,
}

impl CloseGuards {
    pub(crate) fn new() -> Rc<Self> {
        Rc::new(Self {
            turn: futures::lock::Mutex::new(()),
            window: Cell::new(WindowClose::Open),
            teardown_acknowledged: RefCell::new(HashSet::new()),
        })
    }

    async fn run(
        &self,
        parent: &gtk::Widget,
        handle: &WorkspaceHandle,
        scope: CloseScope,
        acknowledged: &mut HashSet<Uuid>,
    ) -> CloseDecision {
        let _turn = self.turn.lock().await;
        CloseGuard::run(parent, handle, scope, acknowledged).await
    }

    /// The window closes only once its prompts approve; `on_close` runs
    /// as it does. A close request while they decide is dropped, since
    /// their dialog is already on screen.
    pub(crate) fn connect_window<W: IsA<gtk::Window>>(
        self: &Rc<Self>,
        window: &W,
        handle: WorkspaceHandle,
        on_close: impl Fn(&W) + 'static,
    ) {
        let guards = self.clone();
        window.connect_close_request(move |window| {
            if !guards.window_may_close(window.upcast_ref(), &handle) {
                return glib::Propagation::Stop;
            }
            on_close(window);
            glib::Propagation::Proceed
        });
    }

    fn window_may_close(self: &Rc<Self>, window: &gtk::Window, handle: &WorkspaceHandle) -> bool {
        match self.window.get() {
            WindowClose::Asking => return false,
            WindowClose::Approved => return true,
            WindowClose::Open => {}
        }
        if handle.close_step(CloseScope::Window, &HashSet::new()) == CloseStep::Approve {
            return true;
        }
        self.window.set(WindowClose::Asking);
        let (guards, handle, window) = (self.clone(), handle.clone(), window.clone());
        glib::spawn_future_local(async move {
            let decision = guards
                .run(window.upcast_ref(), &handle, CloseScope::Window, &mut HashSet::new())
                .await;
            match decision {
                CloseDecision::Approved => {
                    guards.window.set(WindowClose::Approved);
                    window.close();
                }
                CloseDecision::Cancelled => guards.window.set(WindowClose::Open),
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
                .run(&parent, &handle, CloseScope::Tab(tab), &mut HashSet::new())
                .await;
            decided(decision);
        });
    }

    /// A new disconnect or switch asks about every open transaction.
    pub(crate) fn begin_teardown(&self) {
        self.teardown_acknowledged.borrow_mut().clear();
    }

    /// Whether every tab may go with the connection without asking.
    pub(crate) fn may_tear_down(&self, handle: &WorkspaceHandle) -> bool {
        handle.close_step(CloseScope::Window, &self.teardown_acknowledged.borrow()) == CloseStep::Approve
    }

    /// Ask whether every tab may go with the connection; `decided` hears
    /// the answer.
    pub(crate) fn ask_tear_down(
        self: &Rc<Self>,
        parent: &gtk::Widget,
        handle: &WorkspaceHandle,
        decided: impl FnOnce(CloseDecision) + 'static,
    ) {
        let (guards, handle, parent) = (self.clone(), handle.clone(), parent.clone());
        glib::spawn_future_local(async move {
            let mut acknowledged = guards.teardown_acknowledged.borrow().clone();
            let decision = guards
                .run(&parent, &handle, CloseScope::Window, &mut acknowledged)
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
    use crate::test_support::{drain_main_context, wait_until};
    use crate::workspace::dialog_response::{answer, visible_alert};
    use crate::workspace::test_workspace::{WAIT, Workspace};

    fn window() -> adw::Window {
        adw::init().expect("libadwaita initialises under the test backend");
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let window = adw::Window::new();
        window.present();
        window
    }

    /// A window whose close goes through `guards`, and how many times it
    /// closed.
    fn guarded_window(guards: &Rc<CloseGuards>, workspace: &Workspace) -> (adw::Window, Rc<Cell<usize>>) {
        let window = window();
        let closes = Rc::new(Cell::new(0));
        let sink = closes.clone();
        guards.connect_window(&window, workspace.handle.clone(), move |_| sink.set(sink.get() + 1));
        (window, closes)
    }

    /// Wait for an alert with `heading` other than `seen`, and answer it
    /// with `response`. Returns the alert answered.
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
            value: Value::Int(7),
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

    /// libadwaita takes a close request over a dialog as dismissing the
    /// dialog, which keeps the window open.
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
    fn a_teardown_proceeds_only_when_approved() {
        let workspace = Workspace::open(ConnectionScript::default());
        let guards = CloseGuards::new();
        let window = window();
        let parent = window.clone().upcast::<gtk::Widget>();
        assert!(!guards.may_tear_down(&workspace.handle));

        let (kept, sink) = decision_sink();
        guards.ask_tear_down(&parent, &workspace.handle, sink);
        let first = answer_next(&window, "Save Changes?", "cancel", None);
        wait_until(WAIT, || kept.get().is_some()).expect("a decision");
        assert_eq!(kept.get(), Some(CloseDecision::Cancelled));
        assert!(!guards.may_tear_down(&workspace.handle));

        let (approved, sink) = decision_sink();
        guards.ask_tear_down(&parent, &workspace.handle, sink);
        answer_next(&window, "Save Changes?", "discard", Some(&first));
        wait_until(WAIT, || approved.get().is_some()).expect("a decision");
        assert_eq!(approved.get(), Some(CloseDecision::Approved));
        assert!(guards.may_tear_down(&workspace.handle));
    }

    /// A switch asks once before it connects and again before the new
    /// connection replaces the tabs, about what changed in between.
    #[gtk4::test]
    fn a_switch_asks_again_only_about_what_changed_while_connecting() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.open_transaction_tab();
        let guards = CloseGuards::new();
        let window = window();
        let parent = window.clone().upcast::<gtk::Widget>();

        guards.begin_teardown();
        let (approved, sink) = decision_sink();
        guards.ask_tear_down(&parent, &workspace.handle, sink);
        answer_next(&window, "Close With Open Transactions?", "close", None);
        let first = answer_next(&window, "Save Changes?", "discard", None);
        wait_until(WAIT, || approved.get().is_some()).expect("a decision");
        assert!(guards.may_tear_down(&workspace.handle));

        edit_again(&workspace);
        assert!(
            !guards.may_tear_down(&workspace.handle),
            "an edit made while connecting went unasked"
        );
        let (again, sink) = decision_sink();
        guards.ask_tear_down(&parent, &workspace.handle, sink);
        answer_next(&window, "Save Changes?", "discard", Some(&first));
        wait_until(WAIT, || again.get().is_some()).expect("a decision");
        assert_eq!(again.get(), Some(CloseDecision::Approved));

        guards.begin_teardown();
        assert!(
            !guards.may_tear_down(&workspace.handle),
            "a new switch skipped the transaction"
        );
    }
}
