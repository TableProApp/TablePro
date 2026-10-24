use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;

use crate::test_support::{
    ButtonFace, button_face, descendants, has_accessible_label, test_backend_records_properties,
};
use crate::ui::{
    PreferencesDialog, SessionWindow, browse_tab, connect_dialog, diagram, editor, export, filter_strip,
    history_dialog, preferences_dialog, session_window, ssh_section, structure_tab, welcome_view, workspace,
};

/// Every class the app's templates build. A template whose class is
/// missing here fails the walk, so a new one cannot slip past it. The
/// templates nested in another are registered by its class.
fn template_classes() -> Vec<glib::Type> {
    vec![
        browse_tab::BrowseTab::static_type(),
        browse_tab::PagerBar::static_type(),
        browse_tab::PendingChangesBar::static_type(),
        connect_dialog::ConnectDialog::static_type(),
        diagram::DiagramTab::static_type(),
        editor::SqlEditor::static_type(),
        export::ExportOperationsButton::static_type(),
        filter_strip::FilterRuleRow::static_type(),
        filter_strip::FilterStrip::static_type(),
        history_dialog::HistoryDialog::static_type(),
        history_dialog::HistoryRow::static_type(),
        session_window::ConnectFailedPage::static_type(),
        session_window::ConnectingPage::static_type(),
        session_window::PickerPage::static_type(),
        PreferencesDialog::static_type(),
        preferences_dialog::DataBrowserGroup::static_type(),
        preferences_dialog::EditorPage::static_type(),
        preferences_dialog::GeneralPage::static_type(),
        preferences_dialog::HistoryGroup::static_type(),
        SessionWindow::static_type(),
        ssh_section::SshSection::static_type(),
        structure_tab::StructureTab::static_type(),
        welcome_view::WelcomeView::static_type(),
        workspace::Workspace::static_type(),
    ]
}

/// The markup of every template the app registers.
fn app_templates() -> Vec<(String, String)> {
    let dir = format!("{}/ui", crate::config::RESOURCE_BASE_PATH);
    gio::resources_enumerate_children(&dir, gio::ResourceLookupFlags::NONE)
        .expect("the templates are registered")
        .into_iter()
        .map(|name| {
            let path = format!("{dir}/{name}");
            let bytes = gio::resources_lookup_data(&path, gio::ResourceLookupFlags::NONE).expect("a template");
            let markup = String::from_utf8(bytes.to_vec()).expect("UTF-8 markup");
            (name.to_string(), markup)
        })
        .collect()
}

/// The template's class, and its markup with the root turned into a
/// plain object of the parent class, which a GtkBuilder builds without
/// the class, so what the template alone says can be read back. A
/// binding names the class's own properties and a signal the class's own
/// handler, which the parent lacks, and neither says anything about a
/// label, so both go. A property of the class itself set on the root
/// still fails the parse, with an error that names it.
fn plain_template(markup: &str) -> Option<(String, String)> {
    let start = markup.find("<template ")?;
    let end = start + markup[start..].find('>')?;
    let tag = &markup[start..=end];
    let class = attribute(tag, "class")?;
    let parent = attribute(tag, "parent")?;
    let mut plain = format!("{}<object class=\"{parent}\">{}", &markup[..start], &markup[end + 1..]).replacen(
        "</template>",
        "</object>",
        1,
    );
    for binding in ["bind-source", "bind-property", "bind-flags"] {
        plain = without_attribute(&plain, binding);
    }
    Some((class.to_owned(), without_element(&plain, "signal")))
}

fn without_element(markup: &str, name: &str) -> String {
    let open = format!("<{name} ");
    let close = format!("</{name}>");
    let mut kept = String::with_capacity(markup.len());
    let mut rest = markup;
    while let Some(start) = rest.find(&open) {
        kept.push_str(&rest[..start]);
        let element = &rest[start..];
        rest = match element.find('>') {
            Some(end) if element[..end].ends_with('/') => &element[end + 1..],
            Some(_) => element.find(&close).map_or("", |end| &element[end + close.len()..]),
            None => "",
        };
    }
    kept.push_str(rest);
    kept
}

fn without_attribute(markup: &str, name: &str) -> String {
    let key = format!(" {name}=\"");
    let mut kept = String::with_capacity(markup.len());
    let mut rest = markup;
    while let Some(start) = rest.find(&key) {
        kept.push_str(&rest[..start]);
        let value = &rest[start + key.len()..];
        rest = value.find('"').map_or("", |end| &value[end + 1..]);
    }
    kept.push_str(rest);
    kept
}

fn attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let key = format!(" {name}=\"");
    let from = tag.find(&key)? + key.len();
    let len = tag[from..].find('"')?;
    Some(&tag[from..from + len])
}

/// The id GtkBuilder gave the object, unless it made one up.
fn declared_id(widget: &gtk::Widget) -> Option<String> {
    widget
        .buildable_id()
        .map(|id| id.to_string())
        .filter(|id| !id.starts_with("___object_"))
}

/// A button with no text, whose icon the template or the code gives it.
fn needs_label(widget: &gtk::Widget) -> bool {
    matches!(button_face(widget), ButtonFace::Icon | ButtonFace::Empty)
}

/// What is wrong with the icon-only buttons `markup` declares. A button
/// the template labels passes; one it does not must have an id, and be
/// labelled once `class` is built, which is where the code names it.
fn unlabelled_in_template(name: &str, markup: &str, class: Option<glib::Type>) -> Vec<String> {
    let builder = gtk::Builder::new();
    if let Err(error) = builder.add_from_string(markup) {
        return vec![format!("{name}: {error}")];
    }
    let objects = builder.objects();
    let unlabelled: Vec<gtk::Widget> = objects
        .iter()
        .filter_map(|object| object.downcast_ref::<gtk::Widget>())
        .filter(|widget| needs_label(widget) && !has_accessible_label(widget))
        .cloned()
        .collect();
    let instance = class
        .filter(|_| !unlabelled.is_empty())
        .and_then(|class| glib::Object::with_type(class).downcast::<gtk::Widget>().ok());
    let built = instance.as_ref().map(descendants).unwrap_or_default();

    let mut problems = Vec::new();
    for button in unlabelled {
        let kind = button.type_().name();
        let Some(id) = declared_id(&button) else {
            problems.push(format!(
                "{name}: an icon-only {kind} with no id has no accessible label in the template"
            ));
            continue;
        };
        let same: Vec<&gtk::Widget> = built
            .iter()
            .filter(|widget| widget.type_() == button.type_() && declared_id(widget).as_deref() == Some(id.as_str()))
            .collect();
        if same.is_empty() {
            problems.push(format!(
                "{name}: {id} has no accessible label and is not in the built widget"
            ));
        }
        if same
            .iter()
            .any(|widget| needs_label(widget) && !has_accessible_label(widget))
        {
            problems.push(format!("{name}: {id} has no accessible label"));
        }
    }
    let windows = objects
        .iter()
        .filter_map(|object| object.downcast_ref::<gtk::Window>())
        .chain(
            instance
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk::Window>()),
        );
    for window in windows {
        window.destroy();
    }
    problems.sort();
    problems
}

#[gtk4::test]
fn every_icon_only_button_in_a_template_is_labelled() {
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    assert!(
        test_backend_records_properties(),
        "the GTK test accessibility backend is not active; run the tests with GTK_A11Y=test"
    );
    // A class's own init registers the templates nested in it.
    let _classes: Vec<_> = template_classes()
        .into_iter()
        .filter_map(glib::Class::<glib::Object>::from_type)
        .collect();

    let templates = app_templates();
    let mut problems = Vec::new();
    for (name, markup) in &templates {
        let Some((class, plain)) = plain_template(markup) else {
            problems.push(format!("{name}: not a template"));
            continue;
        };
        let Some(class) = glib::Type::from_name(&class) else {
            problems.push(format!("{name}: {class} is not in template_classes"));
            continue;
        };
        problems.extend(unlabelled_in_template(name, &plain, Some(class)));
    }

    assert!(!templates.is_empty(), "the walk found no templates");
    assert!(problems.is_empty(), "{problems:#?}");
}

#[gtk4::test]
fn the_walk_reports_an_unlabelled_icon_button() {
    adw::init().expect("libadwaita initialises under the test backend");
    let markup = r#"<interface>
      <object class="GtkBox">
        <child>
          <object class="GtkButton">
            <property name="icon-name">list-add-symbolic</property>
            <property name="tooltip-text">Add</property>
          </object>
        </child>
        <child>
          <object class="GtkMenuButton" id="named_in_code">
            <property name="icon-name">view-more-symbolic</property>
          </object>
        </child>
        <child>
          <object class="GtkButton">
            <property name="icon-name">user-trash-symbolic</property>
            <accessibility>
              <property name="label">Delete</property>
            </accessibility>
          </object>
        </child>
        <child>
          <object class="GtkButton">
            <property name="label">Save</property>
          </object>
        </child>
      </object>
    </interface>"#;

    let problems = unlabelled_in_template("probe.ui", markup, None);

    assert_eq!(
        problems,
        [
            "probe.ui: an icon-only GtkButton with no id has no accessible label in the template",
            "probe.ui: named_in_code has no accessible label and is not in the built widget",
        ]
    );
}

#[test]
fn a_template_is_read_as_an_object_of_its_parent_class() {
    let markup = r#"<interface><template class="TableProThing" parent="AdwBin"><property name="active" bind-source="TableProThing" bind-property="on" bind-flags="sync-create"/><signal name="notify" handler="on_notify"/><child><object class="GtkButton"><signal name="clicked" handler="on_clicked" swapped="no"></signal></object></child></template></interface>"#;

    assert_eq!(
        plain_template(markup),
        Some((
            "TableProThing".to_owned(),
            r#"<interface><object class="AdwBin"><property name="active"/><child><object class="GtkButton"></object></child></object></interface>"#.to_owned()
        ))
    );
    assert_eq!(plain_template("<interface/>"), None);
}

#[gtk4::test]
fn a_shown_widget_announces_without_an_accessibility_bus() {
    let window = gtk::Window::new();
    let label = gtk::Label::new(Some("Saved"));
    window.set_child(Some(&label));
    window.present();
    crate::test_support::after_next_frame(&label);

    super::announce(&label, "Saved", gtk::AccessibleAnnouncementPriority::Medium);

    assert_eq!(super::announced_in(&label).len(), 1);
    window.destroy();
}
