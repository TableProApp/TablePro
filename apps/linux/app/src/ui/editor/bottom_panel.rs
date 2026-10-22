use std::cell::Cell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};
use tablepro_app_services::editor_panel::{EditorPanel, PanelMode};

use super::{SqlEditor, SqlEditorInput, StatementOutcome, StatementOutcomeKind};

#[derive(Clone, Copy, Debug)]
pub(crate) enum PanelAction {
    Toggle,
    Maximize,
    Results,
    Errors,
}

pub(super) struct BottomPanel {
    paned: gtk::Paned,
    editor: gtk::Box,
    stack: gtk::Stack,
    errors: gtk::Box,
    toggle: gtk::ToggleButton,
    error_button: gtk::Button,
    maximize: gtk::Button,
    state: Rc<Cell<EditorPanel>>,
    applying: Rc<Cell<bool>>,
    return_focus: Rc<gtk::glib::WeakRef<gtk::Widget>>,
}

impl BottomPanel {
    pub(super) fn install(
        toolbar: &adw::ToolbarView,
        paned: &gtk::Paned,
        editor: &gtk::Box,
        results: &gtk::Box,
        sender: &ComponentSender<SqlEditor>,
    ) -> Self {
        paned.set_end_child(None::<&gtk::Widget>);
        let stack = gtk::Stack::builder()
            .hexpand(true)
            .vexpand(true)
            .focusable(true)
            .build();
        stack.add_named(results, Some("results"));
        let errors = gtk::Box::new(gtk::Orientation::Vertical, 8);
        errors.set_margin_start(12);
        errors.set_margin_end(12);
        let scroll = gtk::ScrolledWindow::builder().child(&errors).vexpand(true).build();
        stack.add_named(&scroll, Some("errors"));
        paned.set_end_child(Some(&stack));
        paned.set_wide_handle(true);
        paned.set_resize_start_child(true);
        paned.set_resize_end_child(false);
        paned.set_shrink_start_child(true);
        paned.set_shrink_end_child(true);
        let (bar, toggle, error_button, maximize) = controls(sender);
        toolbar.add_bottom_bar(&bar);
        let state = Rc::new(Cell::new(EditorPanel::default()));
        let applying = Rc::new(Cell::new(false));
        track_divider(paned, &state, &applying);
        let panel = Self {
            paned: paned.clone(),
            editor: editor.clone(),
            stack,
            errors,
            toggle,
            error_button,
            maximize,
            state,
            applying,
            return_focus: Default::default(),
        };
        panel.refresh_errors(&[]);
        panel
    }

    pub(super) fn install_shortcut(root: &impl IsA<gtk::Widget>, sender: &ComponentSender<SqlEditor>) {
        let controller = gtk::ShortcutController::new();
        controller.set_scope(gtk::ShortcutScope::Local);
        controller.set_propagation_phase(gtk::PropagationPhase::Capture);
        let sender = sender.clone();
        controller.add_shortcut(
            gtk::Shortcut::builder()
                .trigger(&crate::ui::shortcut::parse("<Primary>j"))
                .action(&gtk::CallbackAction::new(move |_, _| {
                    sender.input(SqlEditorInput::Panel(PanelAction::Toggle));
                    gtk::glib::Propagation::Stop
                }))
                .build(),
        );
        root.add_controller(controller);
    }

    pub(super) fn track_focus(&self, view: &sourceview5::View) {
        let controller = gtk::EventControllerFocus::new();
        let return_focus = self.return_focus.clone();
        controller.connect_enter(move |controller| {
            if let Some(widget) = controller.widget() {
                return_focus.set(Some(&widget));
            }
        });
        view.add_controller(controller);
    }

    pub(super) fn apply(&self, action: PanelAction) {
        let mut state = self.state.get();
        match action {
            PanelAction::Toggle => state.toggle(),
            PanelAction::Maximize => state.toggle_maximized(),
            PanelAction::Results | PanelAction::Errors => {
                if state.mode() == PanelMode::Hidden {
                    state.show(true);
                }
                self.stack
                    .set_visible_child_name(if matches!(action, PanelAction::Errors) {
                        "errors"
                    } else {
                        "results"
                    });
            }
        }
        self.remember_focus();
        self.state.set(state);
        self.layout();
        if !self.paned.is_mapped() {
            return;
        }
        if state.mode() == PanelMode::Hidden
            || (matches!(action, PanelAction::Maximize) && state.mode() == PanelMode::Docked)
        {
            self.restore_focus();
        } else if !self.stack.child_focus(gtk::DirectionType::TabForward) {
            self.stack.grab_focus();
        }
    }

    pub(super) fn reveal_editor(&self) {
        if self.state.get().mode() == PanelMode::Maximized {
            self.apply(PanelAction::Maximize);
        }
    }

    fn remember_focus(&self) {
        let focus = self.editor.root().and_then(|root| root.focus());
        if let Some(focus) = focus.filter(|focus| focus.is_ancestor(&self.editor)) {
            self.return_focus.set(Some(&focus));
        }
    }

    fn restore_focus(&self) {
        if let Some(focus) = self
            .return_focus
            .upgrade()
            .filter(|focus| focus.is_ancestor(&self.editor) && focus.is_mapped())
            && focus.grab_focus()
        {
            return;
        }
        self.editor.child_focus(gtk::DirectionType::TabForward);
    }

    fn layout(&self) {
        self.applying.set(true);
        let state = self.state.get();
        self.editor.set_visible(state.mode() != PanelMode::Maximized);
        self.stack.set_visible(state.mode() != PanelMode::Hidden);
        self.toggle.set_active(state.mode() != PanelMode::Hidden);
        self.maximize.set_sensitive(state.mode() != PanelMode::Hidden);
        self.maximize.set_icon_name(if state.mode() == PanelMode::Maximized {
            "view-restore-symbolic"
        } else {
            "view-fullscreen-symbolic"
        });
        let tooltip = if state.mode() == PanelMode::Maximized {
            crate::tr!("Restore editor")
        } else {
            crate::tr!("Maximize results")
        };
        self.maximize.set_tooltip_text(Some(&tooltip));
        if state.mode() == PanelMode::Docked && self.paned.height() > 0 {
            self.paned.set_position(state.divider(self.paned.height()));
        }
        self.applying.set(false);
    }

    pub(super) fn show_timeout(&self, message: &str) {
        super::outcomes::clear_box(&self.errors);
        let label = gtk::Label::builder()
            .label(message)
            .selectable(true)
            .wrap(true)
            .xalign(0.0)
            .build();
        self.errors.append(&label);
        self.error_button
            .set_label(&crate::tr!("Errors ({n})").replace("{n}", "1"));
    }

    pub(super) fn refresh_errors(&self, outcomes: &[StatementOutcome]) {
        super::outcomes::clear_box(&self.errors);
        let mut count = 0;
        for outcome in outcomes {
            if let Some(message) = outcome_error(outcome) {
                count += 1;
                let label = gtk::Label::builder()
                    .label(format!(
                        "{} {}: {message}",
                        crate::tr!("Statement"),
                        outcome.identity.statement_index + 1
                    ))
                    .selectable(true)
                    .wrap(true)
                    .xalign(0.0)
                    .build();
                self.errors.append(&label);
                if let Some(button) = message.navigation_button() {
                    self.errors.append(&button);
                }
            }
        }
        self.error_button
            .set_label(&crate::tr!("Errors ({n})").replace("{n}", &count.to_string()));
        if count == 0 {
            self.errors
                .append(&gtk::Label::new(Some(&crate::tr!("No errors in the latest query run"))));
        }
    }
}

fn controls(sender: &ComponentSender<SqlEditor>) -> (gtk::Box, gtk::ToggleButton, gtk::Button, gtk::Button) {
    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    bar.add_css_class("toolbar");
    let toggle = gtk::ToggleButton::builder()
        .label(crate::tr!("Results"))
        .active(true)
        .tooltip_text(crate::tr!("Show or hide query results (Ctrl+J)"))
        .build();
    let sender_toggle = sender.clone();
    toggle.connect_clicked(move |_| sender_toggle.input(SqlEditorInput::Panel(PanelAction::Toggle)));
    let results = gtk::Button::builder()
        .icon_name("view-list-symbolic")
        .tooltip_text(crate::tr!("Show result sets"))
        .build();
    let sender_results = sender.clone();
    results.connect_clicked(move |_| sender_results.input(SqlEditorInput::Panel(PanelAction::Results)));
    let errors = gtk::Button::with_label(&crate::tr!("Errors (0)"));
    let sender_errors = sender.clone();
    errors.connect_clicked(move |_| sender_errors.input(SqlEditorInput::Panel(PanelAction::Errors)));
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    let maximize = gtk::Button::builder()
        .icon_name("view-fullscreen-symbolic")
        .tooltip_text(crate::tr!("Maximize results"))
        .build();
    let sender_max = sender.clone();
    maximize.connect_clicked(move |_| sender_max.input(SqlEditorInput::Panel(PanelAction::Maximize)));
    for child in [
        toggle.upcast_ref::<gtk::Widget>(),
        results.upcast_ref(),
        errors.upcast_ref(),
        spacer.upcast_ref(),
        maximize.upcast_ref(),
    ] {
        bar.append(child);
    }
    (bar, toggle, errors, maximize)
}

fn track_divider(paned: &gtk::Paned, state: &Rc<Cell<EditorPanel>>, applying: &Rc<Cell<bool>>) {
    let state_resize = state.clone();
    let applying_resize = applying.clone();
    paned.connect_position_notify(move |paned| {
        if applying_resize.get() || paned.height() == 0 {
            return;
        }
        let mut state = state_resize.get();
        state.resized(paned.height() - paned.position());
        state_resize.set(state);
    });
    let state_map = state.clone();
    let applying_map = applying.clone();
    paned.connect_map(move |paned| {
        applying_map.set(true);
        if paned.height() > 0 {
            paned.set_position(state_map.get().divider(paned.height()));
        }
        applying_map.set(false);
    });
}

fn outcome_error(outcome: &StatementOutcome) -> Option<super::StatementFailure> {
    match &outcome.kind {
        StatementOutcomeKind::Error(message) => Some(message.clone()),
        StatementOutcomeKind::Streamed(result) => match &result.terminal {
            super::StreamTerminal::Failed(message) => Some(message.clone()),
            super::StreamTerminal::TimedOut => Some(crate::tr!("Query timed out").into()),
            _ => None,
        },
        _ => None,
    }
}
