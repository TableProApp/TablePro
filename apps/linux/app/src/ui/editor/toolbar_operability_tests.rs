use super::*;

#[test]
#[ignore = "requires an isolated GTK display"]
fn narrow_editor_run_and_cancel_buttons_dispatch_inside_their_layout() {
    let fixture = EditorFixture::new();
    let root = fixture.controller.widget();
    let (run_button, cancel_button, run_row, retry_button, source_view) = {
        let model = fixture.controller.model();
        (
            model.run_button.clone(),
            model.cancel_button.clone(),
            model.run_button.parent().unwrap(),
            model.longer_timeout_button.clone(),
            model.source_view.clone(),
        )
    };
    source_view.buffer().set_text("SELECT 1;");

    run_row.add_css_class("resource-toolbar");
    retry_button.add_css_class("resource-toolbar");
    let css = gtk::CssProvider::new();
    css.load_from_string(".resource-toolbar { font-size: 20px; }");
    gtk::style_context_add_provider_for_display(&root.display(), &css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);

    let window = gtk::Window::builder()
        .default_width(600)
        .default_height(700)
        .child(root)
        .build();
    window.present();
    spin_until(|| root.width() > 0 && run_button.width() > 0);
    assert_control_inside_editor(&run_button, root, 600);
    assert!(run_button.is_sensitive());

    run_button.emit_clicked();
    let running = fixture.next_query();
    spin_until(|| fixture.controller.model().cancel_button.is_visible());
    wait_for_layout(&window);
    let cancel_is_visible = cancel_button.is_visible();
    assert_control_inside_editor(&run_button, root, 600);
    assert_control_inside_editor(&cancel_button, root, 600);
    assert!(!fixture.controller.model().run_button.is_sensitive());

    cancel_button.emit_clicked();
    spin_until(|| running.token.is_cancelled());
    fixture.finish(running, Err(DriverError::Cancelled));
    assert!(cancel_is_visible);

    gtk::style_context_remove_provider_for_display(&root.display(), &css);
    window.close();
}

fn assert_control_inside_editor(button: &gtk::Button, root: &impl IsA<gtk::Widget>, width: i32) {
    let bounds = button.compute_bounds(root).unwrap();
    let row_bounds = button.parent().unwrap().compute_bounds(root).unwrap();
    assert!(
        bounds.x() >= 0.0 && bounds.x() + bounds.width() <= width as f32 + 0.5,
        "button={} width={width} bounds={bounds:?} row={row_bounds:?}",
        button.label().unwrap_or_default()
    );
    assert!(button.is_visible());
}

fn wait_for_layout(window: &gtk::Window) {
    let frames = std::rc::Rc::new(std::cell::Cell::new(0));
    let observed = frames.clone();
    window.add_tick_callback(move |_, _| {
        let count = observed.get() + 1;
        observed.set(count);
        if count < 2 {
            gtk::glib::ControlFlow::Continue
        } else {
            gtk::glib::ControlFlow::Break
        }
    });
    spin_until(|| frames.get() >= 2);
}
