use relm4::gtk;
use relm4::gtk::prelude::*;

pub(crate) fn parse(spec: &str) -> gtk::ShortcutTrigger {
    match gtk::ShortcutTrigger::parse_string(spec) {
        Some(trigger) => trigger,
        None => {
            tracing::warn!(spec, "shortcut: unparsable accelerator; it will never fire");
            gtk::NeverTrigger::get().upcast()
        }
    }
}
