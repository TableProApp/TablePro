use super::*;
use tablepro_core::sql_syntax::SqlGrammar;

fn fixture(
    sql: &str,
    cursor: usize,
    index: Rc<RefCell<SchemaIndex>>,
) -> (sourceview5::View, Provider, sourceview5::CompletionContext) {
    let view = sourceview5::View::new();
    view.buffer().set_text(sql);
    view.buffer().place_cursor(&view.buffer().iter_at_offset(cursor as i32));
    let provider = install(index, Default::default());
    view.completion().add_provider(&provider);
    let context = sourceview5::CompletionContext::builder()
        .completion(&view.completion())
        .build();
    (view, provider, context)
}

fn activate(provider: &Provider, context: &sourceview5::CompletionContext, sql: &str) -> String {
    let model = glib::MainContext::default()
        .block_on(provider.populate_future(context))
        .unwrap();
    let proposal = (0..model.n_items())
        .filter_map(|item| model.item(item)?.downcast::<Proposal>().ok())
        .find(|proposal| {
            proposal
                .imp()
                .insertion
                .get()
                .is_some_and(|insertion| insertion.sql == sql)
        })
        .unwrap();
    provider.activate(context, &proposal);
    let buffer = context.buffer().unwrap();
    let (start, end) = buffer.bounds();
    buffer.text(&start, &end, true).to_string()
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn proposals_activate_complete_quoted_references() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().grammar = Some(SqlGrammar::PostgreSql);
    let cases = [
        ("public", "Users", "Us"),
        ("public", "users", "us"),
        ("odd.schema", "a.b", "a"),
        ("public", "a\"b", "a"),
        ("public", "select", "sel"),
        ("public", "東京 with space", "東"),
    ];
    index.borrow_mut().set_tables(
        cases
            .iter()
            .map(|(schema, name, _)| super::super::catalog_reference("postgres", Some(schema), name))
            .collect(),
    );
    for (schema, name, partial) in cases {
        for fragment in [partial.to_string(), format!("\"{partial}"), format!("\"{partial}\"")] {
            assert_table_activation(schema, name, &fragment, index.clone());
        }
    }
}

fn assert_table_activation(schema: &str, name: &str, fragment: &str, index: Rc<RefCell<SchemaIndex>>) {
    let sql = format!("SELECT * FROM {fragment} WHERE true");
    for cursor in [
        "SELECT * FROM ".len(),
        format!("SELECT * FROM {fragment}").chars().count(),
    ] {
        let (_view, provider, context) = fixture(&sql, cursor, index.clone());
        if cursor == "SELECT * FROM ".len() && fragment.starts_with('"') && !fragment.ends_with('"') {
            let model = glib::MainContext::default()
                .block_on(provider.populate_future(&context))
                .unwrap();
            assert_eq!(model.n_items(), 0);
            continue;
        }
        let reference = super::super::catalog_reference("postgres", Some(schema), name);
        assert_eq!(
            activate(&provider, &context, &reference),
            format!("SELECT * FROM {reference} WHERE true")
        );
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn proposals_preserve_aliases_and_replace_only_the_identifier() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().grammar = Some(SqlGrammar::PostgreSql);
    index
        .borrow_mut()
        .set_columns("\"Users\"", vec!["with space".into(), "a.b".into(), "a\"b".into()]);
    let sql = "SELECT u.wrong FROM \"Users\" u";
    let (_view, provider, context) = fixture(sql, "SELECT u.w".len(), index);
    assert_eq!(
        activate(&provider, &context, "\"with space\""),
        "SELECT u.\"with space\" FROM \"Users\" u"
    );
    let buffer = context.buffer().unwrap();
    assert!(buffer.can_undo());
    buffer.undo();
    let (start, end) = buffer.bounds();
    assert_eq!(buffer.text(&start, &end, true).as_str(), sql);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn retired_proposals_do_not_edit_the_buffer() {
    gtk::init().unwrap();
    for retired_by in ["generation", "text", "cursor", "large_buffer"] {
        let index = Rc::new(RefCell::new(SchemaIndex::default()));
        index.borrow_mut().set_tables(vec!["\"Users\"".into()]);
        let (_view, provider, context) = fixture("SELECT * FROM Us", 16, index.clone());
        let model = glib::MainContext::default()
            .block_on(provider.populate_future(&context))
            .unwrap();
        let proposal = model
            .item(0)
            .unwrap()
            .downcast::<sourceview5::CompletionProposal>()
            .unwrap();
        let buffer = context.buffer().unwrap();
        match retired_by {
            "generation" => index.borrow_mut().invalidate_columns(),
            "text" => buffer.set_text("SELECT * FROM other"),
            "large_buffer" => buffer.set_text(&" ".repeat(super::super::sql_text::MAX_ANALYSIS_BYTES + 1)),
            _ => buffer.place_cursor(&buffer.start_iter()),
        }
        let (start, end) = buffer.bounds();
        let before = buffer.text(&start, &end, true);
        provider.activate(&context, &proposal);
        let (start, end) = buffer.bounds();
        assert_eq!(buffer.text(&start, &end, true), before);
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn large_catalog_materializes_only_requested_completion_proposals() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index
        .borrow_mut()
        .set_tables((0..50_000).map(|position| format!("table_{position:05}")).collect());
    let sql = "SELECT * FROM table_";
    let (_view, provider, context) = fixture(sql, sql.len(), index);
    let model = glib::MainContext::default()
        .block_on(provider.populate_future(&context))
        .unwrap();
    assert_eq!(model.n_items(), 50_000);
    let first = model.item(0).unwrap().downcast::<Proposal>().unwrap();
    let insertion = first.imp().insertion.get().unwrap();
    assert_eq!(insertion.sql, "table_00000");
    assert!(Rc::strong_count(&insertion.source) <= 3);
    assert_eq!(model.item(0).unwrap(), first);
    let last = model.item(49_999).unwrap().downcast::<Proposal>().unwrap();
    assert_eq!(last.imp().insertion.get().unwrap().sql, "table_49999");
    assert!(Rc::strong_count(&insertion.source) <= 3);
    assert!(model.item(50_000).is_none());
    provider.activate(&context, &last);
    let buffer = context.buffer().unwrap();
    let (start, end) = buffer.bounds();
    assert_eq!(buffer.text(&start, &end, true).as_str(), "SELECT * FROM table_49999");
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn proposals_first_requested_after_catalog_retirement_do_not_edit_the_buffer() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().set_tables(vec!["orders".into()]);
    let sql = "SELECT * FROM ord";
    let (_view, provider, context) = fixture(sql, sql.len(), index.clone());
    let model = glib::MainContext::default()
        .block_on(provider.populate_future(&context))
        .unwrap();
    index.borrow_mut().invalidate_columns();
    let proposal = model.item(0).unwrap().downcast::<Proposal>().unwrap();
    provider.activate(&context, &proposal);
    let buffer = context.buffer().unwrap();
    let (start, end) = buffer.bounds();
    assert_eq!(buffer.text(&start, &end, true).as_str(), sql);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn completion_resumes_after_a_large_buffer_is_replaced_with_a_small_query() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().grammar = Some(SqlGrammar::PostgreSql);
    index.borrow_mut().set_tables(vec!["users".into()]);
    let large = format!(
        "SELECT * FROM {}us",
        " ".repeat(super::super::sql_text::MAX_ANALYSIS_BYTES)
    );
    let (view, provider, context) = fixture(&large, large.chars().count(), index);
    assert_eq!(provider.model(&context).n_items(), 0);
    view.buffer().set_text("SELECT * FROM us");
    view.buffer().place_cursor(&view.buffer().end_iter());
    assert!(provider.model(&context).n_items() > 0);
    assert_eq!(activate(&provider, &context, "users"), "SELECT * FROM users");
}

fn completion_frame() {
    let ready = Rc::new(std::cell::Cell::new(false));
    let done = ready.clone();
    glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || done.set(true));
    let context = glib::MainContext::default();
    while !ready.get() {
        context.iteration(true);
    }
}

fn completion_popup(widget: &gtk::Widget) -> Option<gtk::Widget> {
    if widget.is::<gtk::Popover>() && widget.has_css_class("completion") {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if let Some(popup) = completion_popup(&current) {
            return Some(popup);
        }
        child = current.next_sibling();
    }
    None
}

fn presented_completion(view: &sourceview5::View, visible: bool, text: &str) -> gtk::Widget {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        completion_frame();
        if let Some(popup) = completion_popup(view.upcast_ref())
            && popup.is_visible() == visible
            && (!visible || (popup.width() > 0 && popup.height() > 0))
        {
            return popup;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "text={text:?}, expected_visible={visible}, mapped={}, focus={}, popup={:?}",
            view.is_mapped(),
            view.has_focus(),
            completion_popup(view.upcast_ref()).map(|popup| (popup.is_visible(), popup.width(), popup.height()))
        );
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn populated_completion_is_presented_after_the_editor_is_rooted() {
    let _application = crate::initialize_ui();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().grammar = Some(SqlGrammar::PostgreSql);
    let (view, provider, context) = fixture("", 0, index);
    let window = gtk::Window::builder()
        .default_width(802)
        .default_height(600)
        .child(&view)
        .build();
    window.present();
    view.grab_focus();
    completion_frame();
    for text in ["do s", "do so", "sel", "do s"] {
        view.buffer().set_text(text);
        view.completion().show();
        let popup = presented_completion(&view, text != "do so", text);
        if text == "do so" {
            assert!(!popup.is_visible());
            continue;
        }
        assert!(popup.is_visible());
        assert!(popup.width() > 0);
        assert!(popup.height() > 0);
    }
    assert_eq!(activate(&provider, &context, "SELECT"), "do SELECT");
    window.close();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn column_refresh_coalesces_a_burst_of_editor_changes() {
    gtk::init().unwrap();
    let calls = Rc::new(std::cell::Cell::new(0));
    let observed = calls.clone();
    let refresh = super::debounce_refresh(Rc::new(move || observed.set(observed.get() + 1)));
    for _ in 0..8 {
        refresh();
    }
    assert_eq!(calls.get(), 0, "metadata refresh ran during the typing burst");
    let context = glib::MainContext::default();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while calls.get() == 0 && std::time::Instant::now() < deadline {
        context.iteration(false);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert_eq!(calls.get(), 1);
    while context.pending() {
        context.iteration(false);
    }
    assert_eq!(calls.get(), 1);
}
