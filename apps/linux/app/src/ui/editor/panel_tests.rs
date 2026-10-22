use super::*;
use crate::ui::editor::bottom_panel::PanelAction;

#[test]
#[ignore = "requires an isolated GTK display"]
fn maximizing_and_hiding_restore_the_split_editor_and_divider() {
    let fixture = EditorFixture::new();
    let window = gtk::Window::builder()
        .default_width(1000)
        .default_height(800)
        .child(fixture.controller.widget())
        .build();
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::SplitToggled(true))
        .unwrap();
    window.present();
    spin_until(|| fixture.controller.model().split_view.secondary_view().is_mapped());
    let secondary = fixture.controller.model().split_view.secondary_view().clone();
    assert!(secondary.grab_focus());
    let paned = descendants(fixture.controller.widget().upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Paned>().ok())
        .find(|paned| paned.orientation() == gtk::Orientation::Vertical)
        .unwrap();
    paned.set_position(300);
    let before = paned.position();
    let maximize = descendants(fixture.controller.widget().upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.tooltip_text().as_deref() == Some("Maximize results"))
        .unwrap();
    maximize.grab_focus();
    maximize.emit_clicked();
    spin_until(|| !secondary.is_mapped());
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::Panel(PanelAction::Maximize))
        .unwrap();
    spin_until(|| secondary.is_mapped());
    assert_eq!(paned.position(), before);
    assert_eq!(
        gtk::prelude::RootExt::focus(&window).as_ref(),
        Some(secondary.upcast_ref())
    );
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::Panel(PanelAction::Maximize))
        .unwrap();
    spin_until(|| !secondary.is_mapped());
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::Panel(PanelAction::Toggle))
        .unwrap();
    spin_until(|| secondary.is_mapped());
    assert_eq!(
        gtk::prelude::RootExt::focus(&window).as_ref(),
        Some(secondary.upcast_ref())
    );
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn the_error_view_retains_results_and_clears_failures_after_success() {
    let fixture = EditorFixture::new();
    fixture.controller.model().run_button.emit_clicked();
    let query = fixture.next_query();
    fixture.finish(query, Err(DriverError::Unsupported("fixture failure".into())));
    let errors = descendants(fixture.controller.widget().upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some("Errors (1)"))
        .unwrap();
    let original = fixture.controller.model().results_holder.first_child().unwrap();
    errors.emit_clicked();
    fixture.process_inputs();
    assert_eq!(fixture.controller.model().results_holder.first_child(), Some(original));
    fixture.controller.model().run_button.emit_clicked();
    let query = fixture.next_query();
    fixture.finish(query, success());
    assert_eq!(errors.label().as_deref(), Some("Errors (0)"));
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn hiding_results_falls_back_when_the_remembered_sql_split_was_closed() {
    let fixture = EditorFixture::new();
    let window = gtk::Window::builder()
        .default_width(1000)
        .default_height(700)
        .child(fixture.controller.widget())
        .build();
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::SplitToggled(true))
        .unwrap();
    window.present();
    spin_until(|| fixture.controller.model().split_view.secondary_view().is_mapped());
    fixture.controller.model().split_view.secondary_view().grab_focus();
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::Panel(PanelAction::Errors))
        .unwrap();
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::SplitToggled(false))
        .unwrap();
    spin_until(|| !fixture.controller.model().split_view.secondary_view().is_mapped());
    fixture
        .controller
        .sender()
        .send(SqlEditorInput::Panel(PanelAction::Toggle))
        .unwrap();
    spin_until(|| {
        gtk::prelude::RootExt::focus(&window).as_ref() == Some(fixture.controller.model().source_view.upcast_ref())
    });
    window.destroy();
}
