use gtk4 as gtk;
use gtk4::prelude::*;

/// A schema's heading in the sidebar, with its "+" button for a new
/// table where the connection's DDL dialect creates tables. ClickHouse
/// does not: a table there needs an engine and a sorting key the
/// structure tab has no place for, so the button would only fail.
pub(super) fn sidebar_section_header(
    schema: Option<&str>,
    can_create_table: bool,
    on_new_table: impl Fn() + 'static,
) -> gtk::Box {
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(12)
        .margin_bottom(6)
        .margin_start(12)
        // Lines the "+" up with the end of the row content.
        .margin_end(12)
        .build();
    let label_text = schema
        .map(str::to_owned)
        .unwrap_or_else(|| crate::i18n::gettext("Tables"));
    let label = gtk::Label::builder()
        .label(&label_text)
        .xalign(0.0)
        .hexpand(true)
        .build();
    // GtkPlacesSidebar's section header: small, bold and dim.
    label.add_css_class("caption-heading");
    label.add_css_class("dim-label");
    header.append(&label);
    if !can_create_table {
        return header;
    }
    // The tooltip says which schema the table goes in.
    let new_table_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::LIST_ADD)
        .tooltip_text(match schema {
            Some(schema) => crate::i18n::gettext_f("New Table in {schema}…", &[("schema", schema)]),
            None => crate::i18n::gettext("New Table…"),
        })
        .valign(gtk::Align::Center)
        .build();
    new_table_button.add_css_class("flat");
    new_table_button.connect_clicked(move |_| on_new_table());
    header.append(&new_table_button);
    header
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::first_descendant_of_type;

    #[gtk4::test]
    fn new_table_button_hidden_without_create_table_capability() {
        let with = sidebar_section_header(Some("public"), true, || {});
        let without = sidebar_section_header(Some("analytics"), false, || {});

        let button = first_descendant_of_type::<gtk::Button>(&with).expect("the new table button");
        assert_eq!(button.tooltip_text().as_deref(), Some("New Table in public…"));
        assert!(
            first_descendant_of_type::<gtk::Button>(&without).is_none(),
            "a connection that cannot create tables offers to"
        );
    }
}
