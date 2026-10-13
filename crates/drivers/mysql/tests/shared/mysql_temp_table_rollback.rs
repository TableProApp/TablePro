use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_temporary_table_creation_survives_rollback_but_its_rows_do_not() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts).await;
    assert_temporary_table_ddl_survives_rollback(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_temporary_table_creation_survives_rollback_but_its_rows_do_not() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts).await;
    assert_temporary_table_ddl_survives_rollback(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_temporary_table_drop_survives_rollback_but_innodb_writes_do_not() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts).await;
    assert_temporary_table_drop_survives_rollback(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_temporary_table_drop_survives_rollback_but_innodb_writes_do_not() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts).await;
    assert_temporary_table_drop_survives_rollback(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_temporary_memory_rows_survive_rollback_but_innodb_writes_do_not() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts).await;
    assert_temporary_memory_rows_survive_rollback(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_temporary_memory_rows_survive_rollback_but_innodb_writes_do_not() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts).await;
    assert_temporary_memory_rows_survive_rollback(conn).await;
}

async fn assert_temporary_table_ddl_survives_rollback(conn: Box<dyn Connection>) {
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    for sql in [
        "START TRANSACTION",
        "CREATE TEMPORARY TABLE rollback_temp_rows (id INT PRIMARY KEY) ENGINE=InnoDB",
        "INSERT INTO rollback_temp_rows VALUES (1)",
        "ROLLBACK",
    ] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }

    let rows = session
        .query_params_controlled("SELECT COUNT(*) FROM rollback_temp_rows", &[], &control)
        .await
        .unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Int(0)]]);
    session.close().await.unwrap();
}

async fn assert_temporary_table_drop_survives_rollback(conn: Box<dyn Connection>) {
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    for sql in [
        "CREATE TABLE rollback_temp_drop_marker (id INT PRIMARY KEY) ENGINE=InnoDB",
        "CREATE TEMPORARY TABLE rollback_temp_dropped (id INT PRIMARY KEY) ENGINE=InnoDB",
        "START TRANSACTION",
        "DROP TEMPORARY TABLE rollback_temp_dropped",
        "INSERT INTO rollback_temp_drop_marker VALUES (1)",
        "ROLLBACK",
    ] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }

    assert!(
        session
            .query_params_controlled("SELECT COUNT(*) FROM rollback_temp_dropped", &[], &control)
            .await
            .is_err()
    );
    let rows = session
        .query_params_controlled("SELECT COUNT(*) FROM rollback_temp_drop_marker", &[], &control)
        .await
        .unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Int(0)]]);
    session.close().await.unwrap();
}

async fn assert_temporary_memory_rows_survive_rollback(conn: Box<dyn Connection>) {
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    for sql in [
        "CREATE TABLE rollback_temp_memory_marker (id INT PRIMARY KEY) ENGINE=InnoDB",
        "START TRANSACTION",
        "CREATE TEMPORARY TABLE rollback_temp_memory (id INT PRIMARY KEY) ENGINE=MEMORY",
        "INSERT INTO rollback_temp_memory_marker VALUES (1)",
        "INSERT INTO rollback_temp_memory VALUES (1)",
        "ROLLBACK",
    ] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }

    let temp_rows = session
        .query_params_controlled("SELECT COUNT(*) FROM rollback_temp_memory", &[], &control)
        .await
        .unwrap();
    assert_eq!(temp_rows.rows, vec![vec![Value::Int(1)]]);
    let innodb_rows = session
        .query_params_controlled("SELECT COUNT(*) FROM rollback_temp_memory_marker", &[], &control)
        .await
        .unwrap();
    assert_eq!(innodb_rows.rows, vec![vec![Value::Int(0)]]);
    session.close().await.unwrap();
}
