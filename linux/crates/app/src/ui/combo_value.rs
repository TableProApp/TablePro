use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

/// GTK keeps a long subtitle on one line while libadwaita's value label can still ellipsize to one
/// character. This value label never shrinks, so the subtitle wraps instead.
pub(crate) fn show_whole_value(row: &adw::ComboRow) {
    // The popup keeps libadwaita's own items, which mark the selected one.
    if row.list_factory().is_none() {
        row.set_list_factory(row.factory().as_ref());
    }
    row.set_factory(Some(&value_factory()));
}

fn value_factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
            let label = gtk::Label::builder().xalign(0.0).valign(gtk::Align::Center).build();
            item.set_child(Some(&label));
        }
    });
    factory.connect_bind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if let (Some(label), Some(choice)) = (
            item.child().and_downcast::<gtk::Label>(),
            item.item().and_downcast::<gtk::StringObject>(),
        ) {
            label.set_label(&choice.string());
        }
    });
    factory
}

/// The label that shows the selected value in the row, not one in the
/// popup.
#[cfg(test)]
pub(crate) fn shown_value(row: &adw::ComboRow) -> Option<gtk::Label> {
    crate::test_support::descendants(row)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .find(|label| {
            label.ancestor(gtk::Popover::static_type()).is_none()
                && label.ancestor(gtk::ListView::static_type()).is_some()
        })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use gtk4 as gtk;
    use gtk4::prelude::*;
    use libadwaita as adw;
    use libadwaita::prelude::*;

    use super::{show_whole_value, shown_value};
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    #[gtk4::test]
    fn the_value_never_asks_for_less_than_its_whole_width() {
        let _ = adw::init();
        let row = adw::ComboRow::builder()
            .title("Encryption")
            .model(&gtk::StringList::new(&["Disable", "Verify full"]))
            .selected(1)
            .build();
        show_whole_value(&row);
        let group = adw::PreferencesGroup::new();
        group.add(&row);
        adw::Window::builder().content(&group).build().present();
        wait_until(WAIT, || shown_value(&row).is_some_and(|label| label.width() > 0)).expect("the row is laid out");

        let value = shown_value(&row).expect("the value label");
        let (minimum, natural, _, _) = value.measure(gtk::Orientation::Horizontal, -1);

        assert_eq!(value.label(), "Verify full");
        assert_eq!(minimum, natural, "the value can be squeezed into an ellipsis");
    }

    #[gtk4::test]
    fn the_popup_keeps_libadwaita_s_own_items() {
        let _ = adw::init();
        let row = adw::ComboRow::new();
        let libadwaita_items = row.factory();

        show_whole_value(&row);

        assert!(libadwaita_items.is_some());
        assert_eq!(row.list_factory(), libadwaita_items);
        assert_ne!(row.factory(), libadwaita_items);
    }
}
