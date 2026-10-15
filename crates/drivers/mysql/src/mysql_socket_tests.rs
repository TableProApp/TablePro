use super::*;

#[test]
fn a_direct_connection_dials_and_verifies_the_same_host() {
    let opts = ConnectOptions {
        host: "db.corp.example".into(),
        port: 3306,
        ..Default::default()
    };

    let mysql_opts = mysql_connect_options(&opts);
    assert_eq!(mysql_opts.get_host(), "db.corp.example");
    assert_eq!(mysql_opts.get_socket(), None);
}

#[test]
fn a_local_socket_connection_dials_the_exact_selected_file() {
    let path = std::path::PathBuf::from("/run/mysqld/mysqld.sock");
    let opts = ConnectOptions {
        host: "localhost".into(),
        port: 3306,
        local_socket_path: Some(path.clone()),
        ..Default::default()
    };

    let mysql_opts = mysql_connect_options(&opts);
    assert_eq!(mysql_opts.get_socket(), Some(&path));
}

#[test]
fn mysql_offers_a_socket_file_but_not_a_socket_directory() {
    assert!(MysqlDriver.supports_local_socket());
    assert!(MysqlDriver.supports_local_socket_file());
    assert!(!MysqlDriver.supports_local_socket_directory());
}
