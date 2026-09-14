use gtk4::prelude::*;
use gtk4::{AccessibleProperty, AccessibleRelation};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::test_support::{UnlabelledWidget, first_descendant_of_type};

pub(crate) fn assert_labelled(widget: &impl IsA<gtk4::Widget>) -> Result<(), UnlabelledWidget> {
    if !test_backend_records_properties() {
        return Err(UnlabelledWidget::TestBackendMissing);
    }
    let widget = widget.as_ref();
    let type_name = widget.type_().name().to_owned();

    let Some(row) = widget.downcast_ref::<adw::PreferencesRow>() else {
        let labelled = gtk4::test_accessible_has_property(widget, AccessibleProperty::Label)
            || gtk4::test_accessible_has_relation(widget, AccessibleRelation::LabelledBy);
        return if labelled {
            Ok(())
        } else {
            Err(UnlabelledWidget::MissingLabel { type_name })
        };
    };

    if row.title().is_empty() {
        return Err(UnlabelledWidget::EmptyRowTitle { type_name });
    }
    if widget.is::<adw::EntryRow>() {
        let labelled = first_descendant_of_type::<gtk4::Text>(widget)
            .is_some_and(|text| gtk4::test_accessible_has_relation(&text, AccessibleRelation::LabelledBy));
        return if labelled {
            Ok(())
        } else {
            Err(UnlabelledWidget::EntryTextNotLabelled { type_name })
        };
    }
    if let Some(action_row) = widget.downcast_ref::<adw::ActionRow>()
        && let Some(activatable) = action_row.activatable_widget()
        && !gtk4::test_accessible_has_relation(&activatable, AccessibleRelation::LabelledBy)
    {
        return Err(UnlabelledWidget::ActivatableWidgetNotLabelled { type_name });
    }
    Ok(())
}

fn test_backend_records_properties() -> bool {
    let probe = gtk4::Button::new();
    probe.update_property(&[gtk4::accessible::Property::Label("probe")]);
    gtk4::test_accessible_has_property(&probe, AccessibleProperty::Label)
}
