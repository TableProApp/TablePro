#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_range_observes_added_label_order_in_same_session() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_alter_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_alter_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_alter_target.state AS ENUM ('queued', 'complete')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_alter_shadow.state AS ENUM ('shadow-only', 'complete')",
        )
        .await
        .unwrap();

    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    session
        .query_params_controlled(
            "SET search_path = value_contract_enum_alter_shadow, \
             value_contract_enum_alter_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();
    let before = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_alter_target.state) AS value",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(before.columns[0].data_type, "value_contract_enum_alter_target.state[]");
    assert_eq!(before.rows[0][0], Value::Text(r#"{"queued","complete"}"#.into()));

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_alter_target.state \
             ADD VALUE 'working' BEFORE 'complete'",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert!(session.is_usable());

    let catalog = session
        .query_params_controlled(
            "SELECT enumlabel::text FROM pg_enum \
             WHERE enumtypid = 'value_contract_enum_alter_target.state'::regtype \
             ORDER BY enumsortorder",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        catalog.rows,
        ["queued", "working", "complete"].map(|label| vec![Value::Text(label.into())])
    );

    let result = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_alter_target.state) AS value",
            &[],
            &control,
        )
        .await
        .unwrap();
    let target_array = "value_contract_enum_alter_target.state[]";
    assert_eq!(result.columns[0].data_type, target_array);
    assert_eq!(result.rows[0][0], Value::Text(r#"{"queued","working","complete"}"#.into()));

    let native = session
        .query_params_controlled(
            "SELECT pg_typeof(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    array_to_json(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    encode(array_send(enum_range(NULL::value_contract_enum_alter_target.state)), 'hex')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(target_array.into()));
    assert_eq!(native.rows[0][1], Value::Text(r#"["queued","working","complete"]"#.into()));
    let rebound = session
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
            std::slice::from_ref(&result.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][2]);

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_alter_target.state \
             ADD VALUE 'starting' AFTER 'queued'",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert!(session.is_usable());

    let result = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_alter_target.state) AS value, \
                    pg_typeof(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    array_to_json(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    encode(array_send(enum_range(NULL::value_contract_enum_alter_target.state)), 'hex')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, target_array);
    assert_eq!(
        result.rows[0][0],
        Value::Text(r#"{"queued","starting","working","complete"}"#.into())
    );
    assert_eq!(result.rows[0][1], Value::Text(target_array.into()));
    assert_eq!(
        result.rows[0][2],
        Value::Text(r#"["queued","starting","working","complete"]"#.into())
    );
    let rebound = session
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
            std::slice::from_ref(&result.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], result.rows[0][3]);

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_alter_target.state ADD VALUE 'archived'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let appended = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_alter_target.state) AS value, \
                    pg_typeof(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    array_to_json(enum_range(NULL::value_contract_enum_alter_target.state))::text, \
                    encode(array_send(enum_range(NULL::value_contract_enum_alter_target.state)), 'hex')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(appended.columns[0].data_type, target_array);
    assert_eq!(
        appended.rows[0][0],
        Value::Text(r#"{"queued","starting","working","complete","archived"}"#.into())
    );
    assert_eq!(appended.rows[0][1], Value::Text(target_array.into()));
    assert_eq!(
        appended.rows[0][2],
        Value::Text(r#"["queued","starting","working","complete","archived"]"#.into())
    );
    let rebound = session
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
            std::slice::from_ref(&appended.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], appended.rows[0][3]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_range_observes_renamed_label_in_same_session() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_rename_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_rename_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_rename_target.state AS ENUM \
             ('queued', 'working', 'complete')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_rename_shadow.state AS ENUM \
             ('shadow-only', 'working', 'complete')",
        )
        .await
        .unwrap();

    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    session
        .query_params_controlled(
            "SET search_path = value_contract_enum_rename_shadow, \
             value_contract_enum_rename_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();
    let query = "SELECT enum_range(NULL::value_contract_enum_rename_target.state) AS value";
    let before = session.query_params_controlled(query, &[], &control).await.unwrap();
    assert_eq!(before.columns[0].data_type, "value_contract_enum_rename_target.state[]");
    assert_eq!(before.rows[0][0], Value::Text(r#"{"queued","working","complete"}"#.into()));

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_rename_target.state \
             RENAME VALUE 'working' TO 'in_progress'",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert!(session.is_usable());

    let catalog = session
        .query_params_controlled(
            "SELECT enumlabel::text FROM pg_enum \
             WHERE enumtypid = 'value_contract_enum_rename_target.state'::regtype \
             ORDER BY enumsortorder",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        catalog.rows,
        ["queued", "in_progress", "complete"].map(|label| vec![Value::Text(label.into())])
    );

    let result = session.query_params_controlled(query, &[], &control).await.unwrap();
    let target_array = "value_contract_enum_rename_target.state[]";
    assert_eq!(result.columns[0].data_type, target_array);
    assert_eq!(result.rows[0][0], Value::Text(r#"{"queued","in_progress","complete"}"#.into()));

    let native = session
        .query_params_controlled(
            "SELECT pg_typeof(enum_range(NULL::value_contract_enum_rename_target.state))::text, \
                    array_to_json(enum_range(NULL::value_contract_enum_rename_target.state))::text, \
                    encode(array_send(enum_range(NULL::value_contract_enum_rename_target.state)), 'hex')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(target_array.into()));
    assert_eq!(native.rows[0][1], Value::Text(r#"["queued","in_progress","complete"]"#.into()));
    let rebound = session
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
            std::slice::from_ref(&result.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][2]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_range_refreshes_labels_changed_by_another_session() {
    let (_container, options) = crate::start_pg().await;
    let setup = crate::connect(options.clone()).await;
    setup
        .execute("CREATE SCHEMA value_contract_enum_cross_session_target")
        .await
        .unwrap();
    setup
        .execute("CREATE SCHEMA value_contract_enum_cross_session_shadow")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_cross_session_target.state AS ENUM ('queued', 'complete')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_cross_session_shadow.state AS ENUM ('shadow-only', 'complete')",
        )
        .await
        .unwrap();

    let reader = crate::connect(options.clone()).await;
    let writer = crate::connect(options).await;
    let mut reader = reader.open_session().await.unwrap();
    let mut writer = writer.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    reader
        .query_params_controlled(
            "SET search_path = value_contract_enum_cross_session_shadow, value_contract_enum_cross_session_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();
    let query =
        "SELECT enum_range(NULL::value_contract_enum_cross_session_target.state) AS value";
    let initial = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    let target_array = "value_contract_enum_cross_session_target.state[]";
    assert_eq!(initial.columns[0].data_type, target_array);
    assert_eq!(initial.rows[0][0], Value::Text(r#"{"queued","complete"}"#.into()));

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_session_target.state ADD VALUE 'working' BEFORE 'complete'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let added = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    assert_eq!(added.columns[0].data_type, target_array);
    assert_eq!(
        added.rows[0][0],
        Value::Text(r#"{"queued","working","complete"}"#.into())
    );

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_session_target.state RENAME VALUE 'working' TO 'in_progress'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let renamed = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    assert_eq!(renamed.columns[0].data_type, target_array);
    assert_eq!(
        renamed.rows[0][0],
        Value::Text(r#"{"queued","in_progress","complete"}"#.into())
    );

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_session_target.state ADD VALUE 'started' AFTER 'queued'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let added_after = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    assert_eq!(added_after.columns[0].data_type, target_array);
    assert_eq!(
        added_after.rows[0][0],
        Value::Text(r#"{"queued","started","in_progress","complete"}"#.into())
    );

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_session_target.state ADD VALUE 'archived'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let appended = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    assert_eq!(appended.columns[0].data_type, target_array);
    assert_eq!(
        appended.rows[0][0],
        Value::Text(r#"{"queued","started","in_progress","complete","archived"}"#.into())
    );

    let native = reader
        .query_params_controlled(
            concat!(
                "SELECT pg_typeof(enum_range(NULL::value_contract_enum_cross_session_target.state))::text, ",
                "array_to_json(enum_range(NULL::value_contract_enum_cross_session_target.state))::text, ",
                "encode(array_send(enum_range(NULL::value_contract_enum_cross_session_target.state)), 'hex'), ",
                "(SELECT string_agg(enumlabel::text, ',' ORDER BY enumsortorder) FROM pg_enum ",
                "WHERE enumtypid = 'value_contract_enum_cross_session_target.state'::regtype)"
            ),
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(target_array.into()));
    assert_eq!(
        native.rows[0][1],
        Value::Text(r#"["queued","started","in_progress","complete","archived"]"#.into())
    );
    assert_eq!(
        native.rows[0][3],
        Value::Text("queued,started,in_progress,complete,archived".into())
    );
    let rebound = reader
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
            std::slice::from_ref(&appended.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][2]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_drop_and_recreate_refreshes_a_warm_session_type_oid() {
    let (_container, options) = crate::start_pg().await;
    let setup = crate::connect(options.clone()).await;
    setup
        .execute("CREATE SCHEMA value_contract_enum_recreate_target")
        .await
        .unwrap();
    setup
        .execute("CREATE SCHEMA value_contract_enum_recreate_shadow")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_recreate_target.state AS ENUM ('old', 'retired')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_recreate_shadow.state AS ENUM ('shadow-only')",
        )
        .await
        .unwrap();

    let reader = crate::connect(options.clone()).await;
    let writer = crate::connect(options.clone()).await;
    let executor = crate::connect(options.clone()).await;
    let mut reader = reader.open_session().await.unwrap();
    let mut writer = writer.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    reader
        .query_params_controlled(
            "SET search_path = value_contract_enum_recreate_shadow, \
             value_contract_enum_recreate_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();

    let query = "SELECT enum_range(NULL::value_contract_enum_recreate_target.state) AS value";
    let pooled_before = setup.query(query).await.unwrap();
    assert_eq!(pooled_before.rows[0][0], Value::Text(r#"{"old","retired"}"#.into()));
    let before = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    let array_type = "value_contract_enum_recreate_target.state[]";
    assert_eq!(before.columns[0].data_type, array_type);
    assert_eq!(before.rows[0][0], Value::Text(r#"{"old","retired"}"#.into()));
    executor.execute(query).await.unwrap();
    let before_oids = reader
        .query_params_controlled(
            "SELECT 'value_contract_enum_recreate_target.state'::regtype::oid::bigint, \
             'value_contract_enum_recreate_target.state[]'::regtype::oid::bigint",
            &[],
            &control,
        )
        .await
        .unwrap();

    writer
        .query_params_controlled(
            "DROP TYPE value_contract_enum_recreate_target.state",
            &[],
            &control,
        )
        .await
        .unwrap();
    writer
        .query_params_controlled(
            "CREATE TYPE value_contract_enum_recreate_target.state AS ENUM ('new', 'NULL', '東京')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert!(reader.is_usable());
    assert!(writer.is_usable());

    // Reuse the exact SQL text on the already-warm reader so PostgreSQL and
    // SQLx must refresh the dropped type and array OIDs.
    let after = reader
        .query_params_controlled(query, &[], &control)
        .await
        .unwrap();
    assert_eq!(after.columns[0].data_type, array_type);
    assert_eq!(after.rows[0][0], Value::Text(r#"{"new","NULL","東京"}"#.into()));
    let pooled_after = setup.query(query).await.unwrap();
    assert_eq!(pooled_after.rows[0][0], after.rows[0][0]);
    executor.execute(query).await.unwrap();

    let native = reader
        .query_params_controlled(
            "SELECT pg_typeof(enum_range(NULL::value_contract_enum_recreate_target.state))::oid::bigint, \
             'value_contract_enum_recreate_target.state'::regtype::oid::bigint, \
             'value_contract_enum_recreate_target.state[]'::regtype::oid::bigint, \
             array_to_json(enum_range(NULL::value_contract_enum_recreate_target.state))::text, \
             encode(array_send(enum_range(NULL::value_contract_enum_recreate_target.state)), 'hex'), \
             (SELECT string_agg(enumlabel::text, ',' ORDER BY enumsortorder) \
              FROM pg_enum WHERE enumtypid = \
                'value_contract_enum_recreate_target.state'::regtype)",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], native.rows[0][2]);
    assert_ne!(native.rows[0][1], before_oids.rows[0][0]);
    assert_ne!(native.rows[0][2], before_oids.rows[0][1]);
    assert_eq!(native.rows[0][3], Value::Text(r#"["new","NULL","東京"]"#.into()));
    assert_eq!(native.rows[0][5], Value::Text("new,NULL,東京".into()));

    let rebound = reader
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{array_type}), 'hex')"),
            std::slice::from_ref(&after.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_type_rename_and_schema_move_refresh_session_metadata() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_move_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_move_shadow").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_move_destination").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_move_target.state AS ENUM ('queued', 'complete')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_move_shadow.state AS ENUM ('shadow-state', 'complete')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_move_shadow.phase AS ENUM ('shadow-phase', 'complete')",
        )
        .await
        .unwrap();

    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    session
        .query_params_controlled(
            "SET search_path = value_contract_enum_move_shadow, \
             value_contract_enum_move_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();

    let initial = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_move_target.state) AS value",
            &[],
            &control,
        )
        .await
        .unwrap();
    let initial_type = "value_contract_enum_move_target.state[]";
    assert_eq!(initial.columns[0].data_type, initial_type);
    assert_eq!(initial.rows[0][0], Value::Text(r#"{"queued","complete"}"#.into()));

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_move_target.state RENAME TO phase",
            &[],
            &control,
        )
        .await
        .unwrap();
    let renamed = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_move_target.phase) AS value",
            &[],
            &control,
        )
        .await
        .unwrap();
    let renamed_type = "value_contract_enum_move_target.phase[]";
    assert_eq!(renamed.columns[0].data_type, renamed_type);
    assert_eq!(renamed.rows[0][0], initial.rows[0][0]);

    session
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_move_target.phase \
             SET SCHEMA value_contract_enum_move_destination",
            &[],
            &control,
        )
        .await
        .unwrap();
    let moved = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_move_destination.phase) AS value",
            &[],
            &control,
        )
        .await
        .unwrap();
    let moved_type = "value_contract_enum_move_destination.phase[]";
    assert_eq!(moved.columns[0].data_type, moved_type);
    assert_eq!(moved.rows[0][0], initial.rows[0][0]);

    let empty = session
        .query_params_controlled(
            "SELECT enum_range(NULL::value_contract_enum_move_destination.phase) AS value \
             WHERE false",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(empty.columns[0].data_type, moved_type);
    assert!(empty.rows.is_empty());

    let native = session
        .query_params_controlled(
            "SELECT pg_typeof(enum_range(NULL::value_contract_enum_move_destination.phase))::text, \
                    array_to_json(enum_range(NULL::value_contract_enum_move_destination.phase))::text, \
                    encode(array_send(enum_range(NULL::value_contract_enum_move_destination.phase)), 'hex')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(moved_type.into()));
    assert_eq!(native.rows[0][1], Value::Text(r#"["queued","complete"]"#.into()));
    let rebound = session
        .query_params_controlled(
            &format!("SELECT encode(array_send($1::text::{moved_type}), 'hex')"),
            std::slice::from_ref(&moved.rows[0][0]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][2]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_type_rename_and_schema_move_refresh_other_session_metadata() {
    let (_container, options) = crate::start_pg().await;
    let setup = crate::connect(options.clone()).await;
    setup.execute("CREATE SCHEMA value_contract_enum_cross_move_target").await.unwrap();
    setup.execute("CREATE SCHEMA value_contract_enum_cross_move_shadow").await.unwrap();
    setup.execute("CREATE SCHEMA value_contract_enum_cross_move_destination").await.unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_cross_move_target.state AS ENUM ('queued', 'complete')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_cross_move_shadow.state AS ENUM ('shadow-state')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TYPE value_contract_enum_cross_move_shadow.phase AS ENUM ('shadow-phase')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE value_contract_enum_cross_move_target.rows \
             (id integer PRIMARY KEY, status value_contract_enum_cross_move_target.state)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO value_contract_enum_cross_move_target.rows VALUES (1, 'queued'), (2, NULL)",
        )
        .await
        .unwrap();

    let reader_connection = crate::connect(options.clone()).await;
    let writer_connection = crate::connect(options).await;
    let mut reader = reader_connection.open_session().await.unwrap();
    let mut writer = writer_connection.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    reader
        .query_params_controlled(
            "SET search_path = value_contract_enum_cross_move_shadow, \
             value_contract_enum_cross_move_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();

    let query = "SELECT id, status AS value FROM \
                 value_contract_enum_cross_move_target.rows ORDER BY id";
    let initial = reader.query_params_controlled(query, &[], &control).await.unwrap();
    assert_eq!(initial.columns[1].data_type, "value_contract_enum_cross_move_target.state");
    assert_eq!(
        initial.rows,
        vec![vec![Value::Int(1), Value::Text("queued".into())], vec![Value::Int(2), Value::Null]]
    );

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_move_target.state RENAME TO phase",
            &[],
            &control,
        )
        .await
        .unwrap();
    let renamed = reader.query_params_controlled(query, &[], &control).await.unwrap();
    assert_eq!(renamed.columns[1].data_type, "value_contract_enum_cross_move_target.phase");
    assert_eq!(renamed.rows, initial.rows);

    writer
        .query_params_controlled(
            "ALTER TYPE value_contract_enum_cross_move_target.phase \
             SET SCHEMA value_contract_enum_cross_move_destination",
            &[],
            &control,
        )
        .await
        .unwrap();
    let moved = reader.query_params_controlled(query, &[], &control).await.unwrap();
    let moved_type = "value_contract_enum_cross_move_destination.phase";
    assert_eq!(moved.columns[1].data_type, moved_type);
    assert_eq!(moved.rows, initial.rows);

    let empty = reader
        .query_params_controlled(
            "SELECT status AS value FROM value_contract_enum_cross_move_target.rows WHERE false",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(empty.columns[0].data_type, moved_type);
    assert!(empty.rows.is_empty());

    let native = reader
        .query_params_controlled(
            "SELECT pg_typeof(status)::text, encode(enum_send(status), 'hex'), \
             (SELECT string_agg(enumlabel::text, ',' ORDER BY enumsortorder) \
              FROM pg_enum WHERE enumtypid = 'value_contract_enum_cross_move_destination.phase'::regtype) \
             FROM value_contract_enum_cross_move_target.rows WHERE id = 1",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(moved_type.into()));
    assert_eq!(native.rows[0][2], Value::Text("queued,complete".into()));
    let rebound = reader
        .query_params_controlled(
            &format!("SELECT encode(enum_send($1::text::{moved_type}), 'hex')"),
            std::slice::from_ref(&moved.rows[0][1]),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][1]);
}
