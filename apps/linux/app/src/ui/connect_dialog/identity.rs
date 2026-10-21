use tablepro_core::ConnectOptions;
use tablepro_storage::{SavedConnection, SavedSshConfig};
use uuid::Uuid;

use crate::ui::ssh_section::SshInputs;

/// Which saved record the dialog is about to write. `bound_id` is set
/// when the dialog was opened against a known connection; it decides on
/// its own and endpoint matching is not consulted.
pub(super) struct ConnectionIdentity<'a> {
    pub bound_id: Option<Uuid>,
    pub driver_id: &'a str,
    pub opts: &'a ConnectOptions,
    pub file_based: bool,
    pub ssh: Option<&'a SshInputs>,
}

/// The name a saved record gets. A name the user typed wins; blank
/// falls back to the endpoint-derived label, which is what every
/// connection saved before naming shipped already carries.
pub(super) fn saved_connection_name(entered: &str, driver_id: &str, opts: &ConnectOptions) -> String {
    let entered = entered.trim();
    if !entered.is_empty() {
        return entered.to_owned();
    }
    derived_connection_name(driver_id, opts)
}

fn derived_connection_name(driver_id: &str, opts: &ConnectOptions) -> String {
    if driver_id == "sqlite" {
        return opts.database.clone();
    }
    if let Some(directory) = &opts.local_socket_dir {
        return format!("{}@{}", opts.username, directory.display());
    }
    if let Some(path) = &opts.local_socket_path {
        return format!("{}@{}", opts.username, path.display());
    }
    if opts.auth_mode == tablepro_core::AuthMode::Kerberos {
        return opts.host.clone();
    }
    format!("{}@{}", opts.username, opts.host)
}

pub(super) async fn find_existing(identity: &ConnectionIdentity<'_>) -> Option<SavedConnection> {
    let existing = tablepro_storage::load_connections().await.ok()?;
    select_existing(&existing, identity).cloned()
}

pub(super) fn select_existing<'a>(
    existing: &'a [SavedConnection],
    identity: &ConnectionIdentity<'_>,
) -> Option<&'a SavedConnection> {
    if let Some(id) = identity.bound_id {
        return existing.iter().find(|saved| saved.id == id);
    }
    let candidates: Vec<_> = existing
        .iter()
        .filter(|saved| matches_endpoint(saved, identity))
        .collect();
    candidates
        .iter()
        .copied()
        .find(|saved| {
            identity.file_based
                || saved.username == identity.opts.username && saved.auth_mode == identity.opts.auth_mode
        })
        .or_else(|| (candidates.len() == 1).then(|| candidates[0]))
}

fn matches_endpoint(saved: &SavedConnection, identity: &ConnectionIdentity<'_>) -> bool {
    let opts = identity.opts;
    if saved.driver_id != identity.driver_id || saved.database != opts.database || saved.auth_source != opts.auth_source
    {
        return false;
    }
    if saved.tls_client_cert != opts.tls.client_cert || saved.tls_client_key != opts.tls.client_key {
        return false;
    }
    if identity.file_based {
        return true;
    }
    match (
        &saved.socket_dir,
        &saved.socket_path,
        &opts.local_socket_dir,
        &opts.local_socket_path,
    ) {
        (Some(saved_dir), None, Some(current_dir), None) => {
            saved_dir == current_dir && saved.port == opts.port && saved.ssh.is_none()
        }
        (None, Some(saved_path), None, Some(current_path)) => saved_path == current_path && saved.ssh.is_none(),
        (None, None, None, None) => {
            saved.host == opts.host && saved.port == opts.port && saved_ssh_matches(&saved.ssh, identity.ssh)
        }
        _ => false,
    }
}

fn saved_ssh_matches(saved: &Option<SavedSshConfig>, current: Option<&SshInputs>) -> bool {
    match (saved, current) {
        (None, None) => true,
        (Some(s), Some(c)) => &c.saved == s,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{AuthMode, Environment, TlsMode};

    fn identity<'a>(driver_id: &'a str, opts: &'a ConnectOptions, file_based: bool) -> ConnectionIdentity<'a> {
        ConnectionIdentity {
            bound_id: None,
            driver_id,
            opts,
            file_based,
            ssh: None,
        }
    }

    fn matches_existing(saved: &SavedConnection, identity: &ConnectionIdentity<'_>) -> bool {
        matches_endpoint(saved, identity)
            && (identity.file_based
                || saved.username == identity.opts.username && saved.auth_mode == identity.opts.auth_mode)
    }

    fn saved(driver_id: &str, username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            auth_source: None,
            id: Uuid::new_v4(),
            name: "saved".into(),
            driver_id: driver_id.into(),
            host: "sql.corp.example".into(),
            port: 1433,
            socket_dir: None,
            socket_path: None,
            database: "sales".into(),
            username: username.into(),
            use_tls: false,
            tls_mode: Some(TlsMode::Disabled),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            auth_mode,
            read_only: false,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn opts(username: &str, auth_mode: AuthMode) -> ConnectOptions {
        ConnectOptions {
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            auth_mode,
            ..Default::default()
        }
    }

    #[test]
    fn file_based_entries_are_identified_by_path() {
        let legacy = saved("sqlite", "postgres", AuthMode::Password);
        let options = opts("", AuthMode::Password);
        assert!(matches_existing(&legacy, &identity("sqlite", &options, true)));
    }

    #[test]
    fn network_entries_distinguish_user_and_auth_mode() {
        let entry = saved("mssql", "sa", AuthMode::Password);
        let same = opts("sa", AuthMode::Password);
        let other_user = opts("other", AuthMode::Password);
        let kerberos = opts("", AuthMode::Kerberos);
        assert!(matches_existing(&entry, &identity("mssql", &same, false)));
        assert!(!matches_existing(&entry, &identity("mssql", &other_user, false)));
        assert!(!matches_existing(&entry, &identity("mssql", &kerberos, false)));
    }

    #[test]
    fn mongodb_entries_distinguish_authentication_databases() {
        let mut entry = saved("mongodb", "reader", AuthMode::Password);
        entry.auth_source = Some("admin".into());
        let same = ConnectOptions {
            auth_source: Some("admin".into()),
            ..opts("reader", AuthMode::Password)
        };
        let different = opts("reader", AuthMode::Password);

        let existing = [entry];
        assert!(select_existing(&existing, &identity("mongodb", &same, false)).is_some());
        assert!(select_existing(&existing, &identity("mongodb", &different, false)).is_none());
    }

    #[test]
    fn network_entries_distinguish_tls_client_identities() {
        let mut entry = saved("postgres", "reader", AuthMode::Password);
        entry.tls_client_cert = Some(std::path::PathBuf::from("/certs/old.crt"));
        entry.tls_client_key = Some(std::path::PathBuf::from("/certs/old.key"));

        let same_identity = ConnectOptions {
            tls: tablepro_core::TlsConfig {
                client_cert: entry.tls_client_cert.clone(),
                client_key: entry.tls_client_key.clone(),
                ..Default::default()
            },
            ..opts("reader", AuthMode::Password)
        };
        let rotated_identity = ConnectOptions {
            tls: tablepro_core::TlsConfig {
                client_cert: Some(std::path::PathBuf::from("/certs/new.crt")),
                client_key: Some(std::path::PathBuf::from("/certs/new.key")),
                ..Default::default()
            },
            ..opts("reader", AuthMode::Password)
        };

        assert!(matches_existing(&entry, &identity("postgres", &same_identity, false)));
        assert!(!matches_existing(
            &entry,
            &identity("postgres", &opts("reader", AuthMode::Password), false)
        ));
        assert!(!matches_existing(
            &entry,
            &identity("postgres", &rotated_identity, false)
        ));
    }

    #[test]
    fn socket_entries_are_distinguished_from_network_entries() {
        let mut entry = saved("postgres", "postgres", AuthMode::Password);
        entry.port = 5432;
        entry.socket_dir = Some(std::path::PathBuf::from("/run/postgresql"));
        let socket_options = ConnectOptions {
            port: 5432,
            database: "sales".into(),
            username: "postgres".into(),
            local_socket_dir: Some(std::path::PathBuf::from("/run/postgresql")),
            ..Default::default()
        };
        let network_options = opts("postgres", AuthMode::Password);

        assert!(matches_existing(&entry, &identity("postgres", &socket_options, false)));
        assert!(!matches_existing(
            &entry,
            &identity("postgres", &network_options, false)
        ));
    }

    #[test]
    fn mysql_socket_entries_match_only_the_same_socket_file() {
        let mut entry = saved("mysql", "root", AuthMode::Password);
        entry.socket_path = Some(std::path::PathBuf::from("/run/mysqld/mysqld.sock"));
        let same_socket = ConnectOptions {
            database: "sales".into(),
            username: "root".into(),
            local_socket_path: entry.socket_path.clone(),
            ..Default::default()
        };
        let different_socket = ConnectOptions {
            local_socket_path: Some(std::path::PathBuf::from("/run/mysqld/other.sock")),
            ..same_socket.clone()
        };

        assert!(matches_existing(&entry, &identity("mysql", &same_socket, false)));
        assert!(!matches_existing(&entry, &identity("mysql", &different_socket, false)));
        assert!(!matches_existing(
            &entry,
            &identity("mysql", &opts("root", AuthMode::Password), false)
        ));
    }

    #[test]
    fn switching_auth_mode_reuses_the_only_endpoint_match() {
        let password = saved("mssql", "sa", AuthMode::Password);
        let options = opts("", AuthMode::Kerberos);
        let selected = select_existing(std::slice::from_ref(&password), &identity("mssql", &options, false));

        assert_eq!(selected.map(|connection| connection.id), Some(password.id));
    }

    #[test]
    fn switching_auth_mode_does_not_guess_between_multiple_accounts() {
        let accounts = [
            saved("mssql", "sa", AuthMode::Password),
            saved("mssql", "reader", AuthMode::Password),
        ];
        let options = opts("", AuthMode::Kerberos);
        let selected = select_existing(&accounts, &identity("mssql", &options, false));

        assert!(selected.is_none());
    }

    #[test]
    fn kerberos_entries_on_one_host_are_distinguished_by_database() {
        let sales = saved("mssql", "", AuthMode::Kerberos);
        let same = opts("", AuthMode::Kerberos);
        let mut finance = opts("", AuthMode::Kerberos);
        finance.database = "finance".into();
        assert!(matches_existing(&sales, &identity("mssql", &same, false)));
        assert!(!matches_existing(&sales, &identity("mssql", &finance, false)));
    }

    #[test]
    fn a_blank_name_falls_back_to_the_endpoint_label() {
        let network = opts("sa", AuthMode::Password);
        assert_eq!(saved_connection_name("   ", "mssql", &network), "sa@sql.corp.example");

        let mut kerberos = opts("", AuthMode::Kerberos);
        kerberos.host = "sql.corp.example".into();
        assert_eq!(saved_connection_name("", "mssql", &kerberos), "sql.corp.example");

        let mut file = opts("", AuthMode::Password);
        file.database = "/tmp/books.db".into();
        assert_eq!(saved_connection_name("", "sqlite", &file), "/tmp/books.db");

        let mut socket = opts("postgres", AuthMode::Password);
        socket.local_socket_dir = Some(std::path::PathBuf::from("/run/postgresql"));
        assert_eq!(
            saved_connection_name("", "postgres", &socket),
            "postgres@/run/postgresql"
        );
    }

    #[test]
    fn a_typed_name_replaces_the_endpoint_label() {
        let network = opts("sa", AuthMode::Password);
        assert_eq!(
            saved_connection_name("  Sales reporting  ", "mssql", &network),
            "Sales reporting"
        );
    }

    #[test]
    fn an_explicit_connection_id_wins_over_endpoint_matching() {
        let first = saved("mssql", "sa", AuthMode::Password);
        let mut second = saved("mssql", "sa", AuthMode::Password);
        second.name = "reporting".into();
        let accounts = [first.clone(), second.clone()];
        let options = opts("sa", AuthMode::Password);

        let mut bound = identity("mssql", &options, false);
        bound.bound_id = Some(second.id);

        assert_eq!(
            select_existing(&accounts, &bound).map(|connection| connection.id),
            Some(second.id)
        );
        assert_eq!(
            select_existing(&accounts, &identity("mssql", &options, false)).map(|connection| connection.id),
            Some(first.id)
        );
    }

    #[test]
    fn an_explicit_id_that_is_no_longer_saved_matches_nothing() {
        let entry = saved("mssql", "sa", AuthMode::Password);
        let options = opts("sa", AuthMode::Password);
        let mut bound = identity("mssql", &options, false);
        bound.bound_id = Some(Uuid::new_v4());

        assert!(select_existing(std::slice::from_ref(&entry), &bound).is_none());
    }
}
