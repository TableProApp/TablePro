use std::rc::Rc;

use gio::prelude::SettingsExt;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;
use tokio::sync::watch;

/// The history preferences, mirrored where the history's worker and the
/// tasks that record can read them.
///
/// `gio::Settings` lives on the GTK thread, so neither can hold it. Each
/// channel keeps the newest value, which is the one a prune or a record
/// must go by.
#[derive(Debug, Clone)]
pub struct HistoryPreferences {
    pub retention_days: watch::Receiver<u32>,
    pub save: watch::Receiver<bool>,
}

impl HistoryPreferences {
    pub fn follow(settings: &Rc<AppSettings>) -> Self {
        Self {
            retention_days: mirror(
                settings,
                keys::HISTORY_RETENTION_DAYS,
                AppSettings::history_retention_days,
            ),
            save: mirror(settings, keys::SAVE_QUERY_HISTORY, AppSettings::save_query_history),
        }
    }
}

fn mirror<T: Send + Sync + 'static>(
    settings: &Rc<AppSettings>,
    key: &str,
    read: fn(&AppSettings) -> T,
) -> watch::Receiver<T> {
    let (sender, receiver) = watch::channel(read(settings));
    let settings_for_change = settings.clone();
    settings.gio().connect_changed(Some(key), move |_, _| {
        sender.send_replace(read(&settings_for_change));
    });
    receiver
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::MemorySettings;

    #[test]
    fn a_changed_preference_reaches_the_channel() {
        let settings = MemorySettings::new();
        let preferences = HistoryPreferences::follow(settings.get());
        assert!(*preferences.save.borrow());

        settings.get().set_save_query_history(false).expect("store the flag");
        settings.get().set_history_retention_days(7).expect("store the days");

        assert!(!*preferences.save.borrow());
        assert_eq!(*preferences.retention_days.borrow(), 7);
    }
}
