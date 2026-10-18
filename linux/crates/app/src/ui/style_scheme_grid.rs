use std::rc::Rc;

use gtk4::prelude::*;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

/// One preview per installed scheme. `StyleSchemePreview` is a toggle,
/// so the group behaves like a radio set: picking one writes the id and
/// clears the rest.
pub(crate) fn populate(container: &gtk4::FlowBox, settings: &Rc<AppSettings>) {
    let manager = sourceview5::StyleSchemeManager::default();
    let selected = settings.style_scheme();
    let previews: Rc<Vec<sourceview5::StyleSchemePreview>> = Rc::new(
        manager
            .scheme_ids()
            .iter()
            .filter_map(|id| manager.scheme(id))
            .map(|scheme| sourceview5::StyleSchemePreview::new(&scheme))
            .collect(),
    );

    for preview in previews.iter() {
        preview.set_selected(preview.scheme().id() == selected);
        let settings = settings.clone();
        let previews = previews.clone();
        preview.connect_activate(move |activated| {
            let id = activated.scheme().id();
            if let Err(error) = settings.set_style_scheme(&id) {
                tracing::warn!(%error, "could not save the editor style scheme");
                return;
            }
            for preview in previews.iter() {
                preview.set_selected(preview.scheme().id() == id);
            }
        });
        container.append(preview);
    }

    let previews_for_settings = previews.clone();
    settings
        .gio()
        .connect_changed(Some(keys::STYLE_SCHEME), move |settings, key| {
            let id = settings.string(key);
            for preview in previews_for_settings.iter() {
                preview.set_selected(preview.scheme().id() == id);
            }
        });
}
