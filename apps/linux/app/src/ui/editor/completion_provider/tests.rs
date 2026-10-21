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
    let provider = install(index);
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
    for (schema, name, _) in cases {
        index
            .borrow_mut()
            .tables
            .push(super::super::catalog_reference("postgres", Some(schema), name));
    }
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
    for retired_by in ["generation", "text", "cursor"] {
        let index = Rc::new(RefCell::new(SchemaIndex::default()));
        index.borrow_mut().tables.push("\"Users\"".into());
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
fn completion_resumes_after_a_large_buffer_is_replaced_with_a_small_query() {
    gtk::init().unwrap();
    let index = Rc::new(RefCell::new(SchemaIndex::default()));
    index.borrow_mut().grammar = Some(SqlGrammar::PostgreSql);
    index.borrow_mut().tables.push("users".into());
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
