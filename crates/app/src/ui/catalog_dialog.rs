use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tokio_util::sync::CancellationToken;

use tablepro_core::{CATALOG_OBJECT_LIMIT, CatalogObject, CatalogObjectKind, DriverError};

use crate::services::database_service::DatabaseService;
use crate::services::preferences::PreferencesStore;
use crate::tr;

struct CatalogSource {
    connection: uuid::Uuid,
    database: std::sync::Arc<DatabaseService>,
    preferences: PreferencesStore,
    in_flight: Rc<RefCell<CancellationToken>>,
}

pub fn present(
    parent: &gtk::Window,
    connection_id: Option<uuid::Uuid>,
    database: &std::sync::Arc<DatabaseService>,
    preferences: &PreferencesStore,
) {
    let Some(connection) = connection_id.filter(|id| database.metadata(*id).is_some()) else {
        let alert = adw::AlertDialog::new(
            Some(&tr!("No active connection")),
            Some(&tr!("Open a connection before browsing its catalog.")),
        );
        alert.add_response("ok", &tr!("OK"));
        alert.present(Some(parent));
        return;
    };
    let source = Rc::new(CatalogSource {
        connection,
        database: database.clone(),
        preferences: preferences.clone(),
        in_flight: Rc::new(RefCell::new(CancellationToken::new())),
    });
    let dialog = adw::Dialog::builder().title(tr!("Catalog")).build();
    dialog.set_content_width(720);
    dialog.set_content_height(560);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    let labels: Vec<String> = CatalogObjectKind::ALL.iter().map(|kind| kind_label(*kind)).collect();
    let label_refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let kinds = gtk::DropDown::from_strings(&label_refs);
    let schema = gtk::SearchEntry::builder()
        .placeholder_text(tr!("All schemas"))
        .hexpand(true)
        .build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    list.add_css_class("boxed-list");
    let status = gtk::Label::builder().xalign(0.0).build();
    status.add_css_class("dim-label");
    toolbar.set_content(Some(&catalog_layout(&kinds, &schema, &list, &status)));
    dialog.set_child(Some(&toolbar));

    let reload = {
        let (source, kinds, schema, list, status) = (
            source.clone(),
            kinds.clone(),
            schema.clone(),
            list.clone(),
            status.clone(),
        );
        Rc::new(move || {
            let kind = CatalogObjectKind::ALL
                .get(kinds.selected() as usize)
                .copied()
                .unwrap_or(CatalogObjectKind::Routine);
            let filter = Some(schema.text().trim().to_string()).filter(|text| !text.is_empty());
            load(&source, kind, filter, &list, &status);
        })
    };
    let on_kind = reload.clone();
    kinds.connect_selected_notify(move |_| on_kind());
    let on_schema = reload.clone();
    schema.connect_activate(move |_| on_schema());
    reload();

    let in_flight = source.in_flight.clone();
    dialog.connect_closed(move |_| in_flight.borrow().cancel());
    dialog.present(Some(parent));
}

fn catalog_layout(
    kinds: &gtk::DropDown,
    schema: &gtk::SearchEntry,
    list: &gtk::ListBox,
    status: &gtk::Label,
) -> gtk::Box {
    let filters = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    filters.append(kinds);
    filters.append(schema);
    let scrolled = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(list)
        .build();
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_start(12)
        .margin_end(12)
        .margin_top(12)
        .margin_bottom(12)
        .build();
    content.append(&filters);
    content.append(&scrolled);
    content.append(status);
    content
}

fn load(
    source: &CatalogSource,
    kind: CatalogObjectKind,
    schema: Option<String>,
    list: &gtk::ListBox,
    status: &gtk::Label,
) {
    list.remove_all();
    let token = replace_in_flight(&source.in_flight);
    let Some(conn) = source.database.get(source.connection) else {
        status.set_text(&tr!("Connection closed."));
        return;
    };
    status.set_text(&tr!("Loading…"));
    let timeout_secs =
        crate::services::operation_control::timeout_for(&source.preferences, &source.database, Some(source.connection));
    let (list, status) = (list.clone(), status.clone());
    glib::spawn_future_local(async move {
        let control = crate::services::operation_control::bounded_with(timeout_secs, token.clone());
        let outcome = conn.list_objects_controlled(kind, schema.as_deref(), &control).await;
        if token.is_cancelled() {
            return;
        }
        if let Ok(objects) = &outcome {
            for object in objects {
                list.append(&object_row(object));
            }
        }
        status.set_text(&outcome_text(kind, &outcome));
    });
}

fn object_row(object: &CatalogObject) -> adw::ActionRow {
    let subtitle = [object.schema.as_deref(), object.detail.as_deref()]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
    adw::ActionRow::builder()
        .title(glib::markup_escape_text(&object.name))
        .subtitle(glib::markup_escape_text(&subtitle))
        .build()
}

fn replace_in_flight(current: &RefCell<CancellationToken>) -> CancellationToken {
    current.borrow().cancel();
    let next = CancellationToken::new();
    *current.borrow_mut() = next.clone();
    next
}

fn kind_label(kind: CatalogObjectKind) -> String {
    match kind {
        CatalogObjectKind::Routine => tr!("Functions and procedures"),
        CatalogObjectKind::Trigger => tr!("Triggers"),
        CatalogObjectKind::Sequence => tr!("Sequences"),
        CatalogObjectKind::Extension => tr!("Extensions"),
        CatalogObjectKind::Role => tr!("Roles"),
        CatalogObjectKind::Type => tr!("Types"),
        CatalogObjectKind::Grant => tr!("Privileges"),
    }
}

fn outcome_text(kind: CatalogObjectKind, outcome: &Result<Vec<CatalogObject>, DriverError>) -> String {
    match outcome {
        Ok(objects) if objects.is_empty() => tr!("Nothing of this kind was found."),
        Ok(objects) if objects.len() >= CATALOG_OBJECT_LIMIT => {
            tr!("Showing the first {limit}. Narrow the schema to see the rest.")
                .replace("{limit}", &CATALOG_OBJECT_LIMIT.to_string())
        }
        Ok(objects) => tr!("{count} found").replace("{count}", &objects.len().to_string()),
        Err(DriverError::Unsupported(_)) => {
            tr!("This engine does not list {kind}.").replace("{kind}", &kind_label(kind).to_lowercase())
        }
        Err(DriverError::PolicyDenied(_)) => tr!("Policy does not allow this listing."),
        Err(error) => crate::ui::error_text::driver_message(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(name: &str) -> CatalogObject {
        CatalogObject {
            kind: CatalogObjectKind::Trigger,
            schema: Some("public".into()),
            name: name.into(),
            detail: None,
        }
    }

    #[test]
    fn empty_unsupported_denied_and_failed_listings_read_differently() {
        let kind = CatalogObjectKind::Trigger;
        let texts = [
            outcome_text(kind, &Ok(Vec::new())),
            outcome_text(kind, &Err(DriverError::Unsupported("x".into()))),
            outcome_text(kind, &Err(DriverError::PolicyDenied("x".into()))),
            outcome_text(kind, &Err(DriverError::Disconnected)),
        ];
        for (index, text) in texts.iter().enumerate() {
            assert!(!text.is_empty());
            assert!(texts.iter().skip(index + 1).all(|other| other != text), "{texts:?}");
        }
        assert!(texts[1].contains("triggers"), "{}", texts[1]);
    }

    #[test]
    fn a_listing_that_reaches_the_limit_says_it_was_cut_short() {
        let full: Vec<CatalogObject> = (0..CATALOG_OBJECT_LIMIT).map(|i| object(&i.to_string())).collect();

        assert!(outcome_text(CatalogObjectKind::Trigger, &Ok(full)).contains("first"));
        assert_eq!(
            outcome_text(CatalogObjectKind::Trigger, &Ok(vec![object("a")])),
            "1 found"
        );
    }
}
