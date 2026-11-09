use std::rc::Rc;

use gtk4::prelude::*;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;

use crate::ui::handler_guard::HandlerGuard;

pub(crate) fn populate(container: &gtk4::FlowBox, settings: &Rc<AppSettings>) -> HandlerGuard {
    let manager = sourceview5::StyleSchemeManager::default();
    let selected = settings.style_scheme();
    let mut previews = Vec::new();
    for scheme in manager.scheme_ids().iter().filter_map(|id| manager.scheme(id)) {
        let preview = sourceview5::StyleSchemePreview::new(&scheme);
        preview.set_selected(scheme.id() == selected);
        let settings = settings.clone();
        preview.connect_activate(move |activated| {
            if let Err(error) = settings.set_style_scheme(&activated.scheme().id()) {
                tracing::warn!(%error, "could not save the editor style scheme");
            }
        });
        previews.push(preview.downgrade());
        container.append(&preview);
    }

    // Settings outlive Preferences; they must not keep the previews alive.
    let changed = settings
        .gio()
        .connect_changed(Some(keys::STYLE_SCHEME), move |settings, key| {
            let id = settings.string(key);
            for preview in previews.iter().filter_map(gtk4::glib::WeakRef::upgrade) {
                preview.set_selected(preview.scheme().id() == id);
            }
        });
    HandlerGuard::new(settings.gio(), changed)
}
