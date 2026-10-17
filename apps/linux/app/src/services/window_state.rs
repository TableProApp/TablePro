use std::cell::RefCell;
use std::rc::{Rc, Weak};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use gtk4::gio;
use gtk4::gio::prelude::*;
use tablepro_app_services::window_state;
pub use tablepro_app_services::window_state::WindowState;

use super::config_io::{atomic_write_json, backup_file_if_exists, xdg_config_path};

static FILE_LOCK: Mutex<()> = Mutex::new(());
static SESSION_RESTORE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
static SAVE_GENERATION: AtomicU64 = AtomicU64::new(0);

thread_local! {
    static SHARED_STATE: RefCell<Weak<RefCell<WindowState>>> = const { RefCell::new(Weak::new()) };
}

#[derive(Debug, PartialEq, Eq)]
enum GeometrySync {
    Nothing,
    MigrateFileToSettings,
    WriteStateToSettings,
}

struct SettingsGeometry {
    width: i32,
    height: i32,
    maximized: bool,
    migrated: bool,
}

fn reconcile(parsed: Option<WindowState>, settings: Option<SettingsGeometry>) -> (WindowState, GeometrySync) {
    let unreadable = parsed.is_none();
    let mut state = parsed.unwrap_or_default();
    let sync = match settings {
        None => GeometrySync::Nothing,
        Some(settings) if !settings.migrated => GeometrySync::MigrateFileToSettings,
        Some(settings) if unreadable => {
            state.width = settings.width;
            state.height = settings.height;
            state.maximized = settings.maximized;
            GeometrySync::Nothing
        }
        Some(settings)
            if state.width != settings.width
                || state.height != settings.height
                || state.maximized != settings.maximized =>
        {
            GeometrySync::WriteStateToSettings
        }
        Some(_) => GeometrySync::Nothing,
    };
    (window_state::sane(state), sync)
}

fn load_locked() -> WindowState {
    let Some(path) = xdg_config_path("window.json") else {
        return WindowState::default();
    };
    let parsed: Option<WindowState> = std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let settings = super::preferences::settings();
    let geometry = settings.as_ref().map(|settings| SettingsGeometry {
        width: settings.int("window-width"),
        height: settings.int("window-height"),
        maximized: settings.boolean("window-maximized"),
        migrated: settings.boolean("window-migrated"),
    });
    let (state, sync) = reconcile(parsed, geometry);
    if let Some(settings) = settings {
        match sync {
            GeometrySync::Nothing => {}
            GeometrySync::MigrateFileToSettings => {
                if let Err(e) = backup_file_if_exists(&path, &path.with_extension("before-gsettings.json"))
                    .map_err(|e| e.to_string())
                    .and_then(|()| save_geometry_settings(&settings, &state))
                {
                    tracing::warn!(error = %e, "window_state: GSettings migration deferred");
                }
            }
            GeometrySync::WriteStateToSettings => {
                if let Err(e) = save_geometry_settings(&settings, &state) {
                    tracing::warn!(error = %e, "window_state: rollback changes not synced to GSettings");
                }
            }
        }
    }
    state
}

fn save_geometry_settings(settings: &gio::Settings, state: &WindowState) -> Result<(), String> {
    settings.delay();
    let result = (|| {
        settings.set_int("window-width", state.width)?;
        settings.set_int("window-height", state.height)?;
        settings.set_boolean("window-maximized", state.maximized)?;
        settings.set_boolean("window-migrated", true)?;
        Ok::<(), glib::BoolError>(())
    })();
    if let Err(e) = result {
        settings.revert();
        return Err(e.to_string());
    }
    settings.apply();
    Ok(())
}

pub fn load() -> WindowState {
    let _guard = FILE_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    load_locked()
}

pub fn shared() -> Rc<RefCell<WindowState>> {
    SHARED_STATE.with(|shared| {
        if let Some(state) = shared.borrow().upgrade() {
            return state;
        }
        let state = Rc::new(RefCell::new(load()));
        *shared.borrow_mut() = Rc::downgrade(&state);
        state
    })
}

pub fn next_save_generation() -> u64 {
    SAVE_GENERATION.fetch_add(1, Ordering::SeqCst).wrapping_add(1)
}

pub fn save(state: &WindowState, generation: u64) -> Result<(), String> {
    let _guard = FILE_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if generation != SAVE_GENERATION.load(Ordering::SeqCst) {
        return Ok(());
    }
    let path = xdg_config_path("window.json").ok_or_else(|| "configuration path is unavailable".to_owned())?;
    if let Some(settings) = super::preferences::settings()
        && !settings.boolean("window-migrated")
    {
        backup_file_if_exists(&path, &path.with_extension("before-gsettings.json"))
            .map_err(|error| error.to_string())?;
    }
    atomic_write_json(&path, state).map_err(|error| error.to_string())?;
    if let Some(settings) = super::preferences::settings() {
        save_geometry_settings(&settings, state)?;
    }
    Ok(())
}

pub fn take_session_restore_turn() -> bool {
    !SESSION_RESTORE_ATTEMPTED.swap(true, Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn app_windows_share_one_loaded_state_snapshot() {
        assert!(Rc::ptr_eq(&shared(), &shared()));
    }

    #[test]
    fn a_missing_last_connection_id_deserializes_as_none() {
        let parsed: WindowState =
            serde_json::from_str(r#"{"width":800,"height":600,"maximized":false}"#).expect("legacy window.json");
        assert_eq!(parsed.last_connection_id, None);
        assert_eq!(parsed.width, 800);
    }

    #[test]
    fn last_connection_id_round_trips() {
        let id = Uuid::new_v4();
        let state = WindowState {
            width: 1,
            height: 2,
            maximized: true,
            last_connection_id: Some(id),
        };
        let parsed: WindowState =
            serde_json::from_slice(&serde_json::to_vec(&state).expect("serialize")).expect("deserialize");
        assert_eq!(parsed.last_connection_id, Some(id));
        assert!(parsed.maximized);
    }

    #[test]
    fn restore_skips_an_unknown_or_absent_connection() {
        let id = Uuid::new_v4();
        assert_eq!(window_state::connection_id_to_restore(None, &[id]), None);
        assert_eq!(window_state::connection_id_to_restore(Some(id), &[]), None);
        assert_eq!(
            window_state::connection_id_to_restore(Some(Uuid::new_v4()), &[id]),
            None
        );
        assert_eq!(window_state::connection_id_to_restore(Some(id), &[id]), Some(id));
    }
    fn state(width: i32, height: i32, maximized: bool) -> WindowState {
        WindowState {
            width,
            height,
            maximized,
            last_connection_id: None,
        }
    }

    fn settings(width: i32, height: i32, maximized: bool, migrated: bool) -> Option<SettingsGeometry> {
        Some(SettingsGeometry {
            width,
            height,
            maximized,
            migrated,
        })
    }

    #[test]
    fn a_corrupt_or_missing_window_file_adopts_the_saved_geometry_and_writes_nothing_back() {
        let (loaded, sync) = reconcile(None, settings(1500, 900, true, true));
        assert_eq!((loaded.width, loaded.height, loaded.maximized), (1500, 900, true));
        assert_eq!(
            sync,
            GeometrySync::Nothing,
            "the default must not be written over the user's geometry"
        );
    }

    #[test]
    fn the_first_run_after_an_upgrade_migrates_the_file_even_when_it_is_unreadable() {
        let (_, sync) = reconcile(Some(state(1000, 700, false)), settings(1200, 760, false, false));
        assert_eq!(sync, GeometrySync::MigrateFileToSettings);
        let (_, sync) = reconcile(None, settings(1200, 760, false, false));
        assert_eq!(sync, GeometrySync::MigrateFileToSettings);
    }

    #[test]
    fn a_readable_file_that_differs_from_the_settings_is_written_to_them() {
        let (loaded, sync) = reconcile(Some(state(1000, 700, false)), settings(1200, 760, false, true));
        assert_eq!((loaded.width, loaded.height), (1000, 700));
        assert_eq!(sync, GeometrySync::WriteStateToSettings);
        let (_, same) = reconcile(Some(state(1000, 700, false)), settings(1000, 700, false, true));
        assert_eq!(same, GeometrySync::Nothing);
        let (_, none) = reconcile(Some(state(1000, 700, false)), None);
        assert_eq!(none, GeometrySync::Nothing);
    }

    #[test]
    fn a_size_from_a_hand_edited_file_or_the_settings_is_clamped_before_it_reaches_the_toolkit() {
        for (width, height) in [(-7, 99_999_999), (0, 0), (i32::MIN, i32::MAX)] {
            let (from_file, _) = reconcile(Some(state(width, height, false)), None);
            let (from_settings, _) = reconcile(None, settings(width, height, false, true));
            for loaded in [from_file, from_settings] {
                assert!((480..=16384).contains(&loaded.width), "{width}: {}", loaded.width);
                assert!((320..=16384).contains(&loaded.height), "{height}: {}", loaded.height);
            }
        }
        let (ordinary, _) = reconcile(Some(state(1180, 740, false)), None);
        assert_eq!((ordinary.width, ordinary.height), (1180, 740));
    }
}
