use relm4::adw::prelude::*;
use tablepro_core::AuthMode;
use tablepro_core::{ConnectionFormDefaults, DatabaseDriver, connection_form_defaults};

pub(super) fn apply_driver_values(
    dialog: &mut super::ConnectDialog,
    index: u32,
) -> Option<std::sync::Arc<dyn DatabaseDriver>> {
    let previous_index = dialog.applied_driver;
    dialog.applied_driver = Some(index);
    let entry = dialog.drivers.get(index as usize)?;
    let driver = dialog.registry.get(&entry.id)?;
    let defaults = connection_form_defaults(driver.as_ref());
    let previous = previous_index
        .and_then(|previous| dialog.drivers.get(previous as usize))
        .and_then(|entry| dialog.registry.get(&entry.id))
        .map(|driver| connection_form_defaults(driver.as_ref()));
    apply_values(&dialog.port, &dialog.database, &dialog.username, previous, defaults);
    Some(driver)
}

impl super::ConnectDialog {
    pub(super) fn apply_driver_form_visibility(&mut self, driver: &dyn tablepro_core::DatabaseDriver) {
        self.form.file_based = driver.is_file_based();
        self.form.supports_integrated = driver.supports_integrated_auth();
        self.form.supports_local_socket = driver.supports_local_socket();
        if !self.form.supports_local_socket {
            self.endpoint_combo.set_selected(0);
        }
        self.apply_form_state();
        self.configure_socket_field(driver.id());
        self.apply_tls_visibility();
        self.database_file_picker.set_visible(self.form.file_based);
        self.auth_source.set_visible(driver.id() == "mongodb");
        self.database.set_title(&if self.form.file_based {
            crate::tr!("File path")
        } else {
            crate::tr!("Database")
        });
    }
}

fn apply_values(
    port: &relm4::gtk::SpinButton,
    database: &relm4::adw::EntryRow,
    username: &relm4::adw::EntryRow,
    previous: Option<ConnectionFormDefaults>,
    next: ConnectionFormDefaults,
) {
    port.set_value(next_driver_value(port.value() as u16, previous.map(|value| value.port), next.port) as f64);
    database.set_text(&next_driver_text(
        &database.text(),
        previous.map(|value| value.database),
        next.database,
    ));
    username.set_text(&next_driver_text(
        &username.text(),
        previous.map(|value| value.username),
        next.username,
    ));
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct AuthFormState {
    pub(super) file_based: bool,
    pub(super) supports_integrated: bool,
    pub(super) supports_local_socket: bool,
    pub(super) selected: AuthMode,
}

impl AuthFormState {
    pub(super) fn mode(self) -> AuthMode {
        if self.shows_method() {
            self.selected
        } else {
            AuthMode::Password
        }
    }

    pub(super) fn shows_method(self) -> bool {
        !self.file_based && self.supports_integrated
    }

    pub(super) fn shows_credentials(self) -> bool {
        !self.file_based && self.mode() == AuthMode::Password
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct EndpointFormState {
    pub(super) file_based: bool,
    pub(super) supports_local_socket: bool,
    pub(super) socket_selected: bool,
}

impl EndpointFormState {
    pub(super) fn shows_endpoint_choice(self) -> bool {
        !self.file_based && self.supports_local_socket
    }

    pub(super) fn uses_local_socket(self) -> bool {
        self.shows_endpoint_choice() && self.socket_selected
    }

    pub(super) fn shows_network(self) -> bool {
        !self.file_based && !self.uses_local_socket()
    }

    pub(super) fn shows_port(self) -> bool {
        !self.file_based
    }

    pub(super) fn shows_socket_rows(self) -> bool {
        self.uses_local_socket()
    }
}

pub(super) fn socket_directory_is_valid(directory: &str) -> bool {
    std::path::Path::new(directory).is_absolute()
}

pub(super) fn resolved_socket_path(directory: &str, port: u16) -> std::path::PathBuf {
    std::path::Path::new(directory).join(format!(".s.PGSQL.{port}"))
}

pub(super) fn local_socket_options(
    driver_id: &str,
    endpoint: &str,
) -> (Option<std::path::PathBuf>, Option<std::path::PathBuf>) {
    let path = std::path::PathBuf::from(endpoint);
    if driver_id == "mysql" {
        (None, Some(path))
    } else {
        (Some(path), None)
    }
}

pub(super) fn test_result_text(result: &Result<usize, String>) -> String {
    match result {
        Ok(tables) => crate::tr!("Connection ok · {n} table(s) visible").replace("{n}", &tables.to_string()),
        Err(error) => crate::tr!("Test failed: {error}").replace("{error}", error),
    }
}

pub(super) fn default_driver_row(drivers: &[super::DriverEntry]) -> u32 {
    drivers.iter().position(|d| d.id == "postgres").unwrap_or(0) as u32
}

pub(super) fn next_driver_value<T: PartialEq + Copy>(current: T, previous: Option<T>, next: T) -> T {
    if previous.is_some_and(|previous| current != previous) {
        current
    } else {
        next
    }
}

pub(super) fn next_driver_text(current: &str, previous: Option<&str>, next: &str) -> String {
    if previous.is_some_and(|previous| current != previous) {
        current.to_owned()
    } else {
        next.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switching_drivers_updates_only_fields_still_at_the_previous_default() {
        let port = next_driver_value(5432, Some(5432), 3306);
        let custom_port = next_driver_value(55432, Some(5432), 3306);
        let database = next_driver_text("postgres", Some("postgres"), "mysql");
        let custom_database = next_driver_text("shop", Some("postgres"), "mysql");
        let username = next_driver_text("postgres", Some("postgres"), "root");
        let custom_username = next_driver_text("bookie", Some("postgres"), "root");

        assert_eq!((port, database.as_str(), username.as_str()), (3306, "mysql", "root"));
        assert_eq!(
            (custom_port, custom_database.as_str(), custom_username.as_str()),
            (55432, "shop", "bookie")
        );
    }

    #[test]
    fn the_first_driver_selection_applies_its_defaults() {
        assert_eq!(next_driver_value(0, None, 3306), 3306);
        assert_eq!(next_driver_text("", None, "mysql"), "mysql");
    }

    #[test]
    fn auth_form_state_drives_mode_and_visibility() {
        let cases = [
            (AuthFormState::default(), AuthMode::Password, false, true),
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: true,
                    supports_local_socket: false,
                    selected: AuthMode::Password,
                },
                AuthMode::Password,
                true,
                true,
            ),
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: true,
                    supports_local_socket: false,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Kerberos,
                true,
                false,
            ),
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: false,
                    supports_local_socket: false,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Password,
                false,
                true,
            ),
            (
                AuthFormState {
                    file_based: true,
                    supports_integrated: true,
                    supports_local_socket: false,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Password,
                false,
                false,
            ),
        ];
        for (state, mode, method, credentials) in cases {
            assert_eq!(state.mode(), mode, "{state:?}");
            assert_eq!(state.shows_method(), method, "{state:?}");
            assert_eq!(state.shows_credentials(), credentials, "{state:?}");
        }
    }

    #[test]
    fn a_file_based_driver_never_offers_an_endpoint_choice() {
        let state = EndpointFormState {
            file_based: true,
            supports_local_socket: false,
            socket_selected: true,
        };
        assert!(!state.shows_endpoint_choice());
        assert!(!state.uses_local_socket());
        assert!(!state.shows_socket_rows());
        assert!(!state.shows_network());
        assert!(!state.shows_port());
    }

    #[test]
    fn a_driver_without_socket_support_stays_on_the_network_form() {
        let state = EndpointFormState {
            file_based: false,
            supports_local_socket: false,
            socket_selected: true,
        };
        assert!(!state.shows_endpoint_choice());
        assert!(!state.uses_local_socket());
        assert!(state.shows_network());
        assert!(state.shows_port());
        assert!(!state.shows_socket_rows());
    }

    #[test]
    fn selecting_the_socket_endpoint_hides_every_network_row() {
        let state = EndpointFormState {
            file_based: false,
            supports_local_socket: true,
            socket_selected: true,
        };
        assert!(state.shows_endpoint_choice());
        assert!(state.uses_local_socket());
        assert!(state.shows_socket_rows());
        assert!(!state.shows_network());
        assert!(state.shows_port());
    }

    #[test]
    fn returning_to_the_network_endpoint_restores_the_network_rows() {
        let state = EndpointFormState {
            file_based: false,
            supports_local_socket: true,
            socket_selected: false,
        };
        assert!(state.shows_endpoint_choice());
        assert!(!state.uses_local_socket());
        assert!(!state.shows_socket_rows());
        assert!(state.shows_network());
    }

    #[test]
    fn a_socket_directory_must_be_absolute() {
        assert!(socket_directory_is_valid("/run/postgresql"));
        assert!(socket_directory_is_valid("/tmp"));
        assert!(!socket_directory_is_valid("run/postgresql"));
        assert!(!socket_directory_is_valid(""));
        assert!(!socket_directory_is_valid("~/sockets"));
    }

    #[test]
    fn the_resolved_socket_follows_the_directory_and_port() {
        assert_eq!(
            resolved_socket_path("/run/postgresql", 5432),
            std::path::PathBuf::from("/run/postgresql/.s.PGSQL.5432")
        );
        assert_eq!(
            resolved_socket_path("/tmp", 6543),
            std::path::PathBuf::from("/tmp/.s.PGSQL.6543")
        );
    }

    #[test]
    fn postgres_keeps_directory_sockets_and_mysql_uses_a_socket_file() {
        assert_eq!(
            local_socket_options("postgres", "/run/postgresql"),
            (Some(std::path::PathBuf::from("/run/postgresql")), None)
        );
        assert_eq!(
            local_socket_options("mysql", "/run/mysqld/mysqld.sock"),
            (None, Some(std::path::PathBuf::from("/run/mysqld/mysqld.sock")))
        );
    }

    fn driver(id: &str) -> crate::ui::connect_dialog::DriverEntry {
        crate::ui::connect_dialog::DriverEntry {
            id: id.to_string(),
            display_name: id.to_string(),
            maturity: tablepro_core::DriverMaturity::Stable,
        }
    }

    #[test]
    fn a_new_connection_starts_on_postgres_when_it_is_registered() {
        let drivers = [driver("clickhouse"), driver("mysql"), driver("postgres")];
        assert_eq!(default_driver_row(&drivers), 2);
    }

    #[test]
    fn the_default_driver_falls_back_to_the_first_row() {
        assert_eq!(default_driver_row(&[driver("clickhouse"), driver("sqlite")]), 0);
        assert_eq!(default_driver_row(&[]), 0);
    }

    #[test]
    fn a_test_result_names_the_table_count_or_the_failure() {
        assert_eq!(test_result_text(&Ok(3)), "Connection ok · 3 table(s) visible");
        assert_eq!(
            test_result_text(&Err("password rejected".into())),
            "Test failed: password rejected"
        );
    }
}
