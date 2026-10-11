use super::parse_input_for_driver;
use tablepro_core::{ColumnInfo, Value};

fn col(data_type: &str, nullable: bool) -> ColumnInfo {
    ColumnInfo {
        name: "value".into(),
        data_type: data_type.into(),
        nullable,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn value_contract_mysql_spatial_parser_refuses_lossy_text_edits() {
    for data_type in [
        "geometry",
        "point",
        "linestring",
        "polygon",
        "multipoint",
        "multilinestring",
        "multipolygon",
        "geometrycollection",
    ] {
        let column = col(data_type, false);
        assert!(
            parse_input_for_driver("POINT(9 9)", Some(&column), "mysql").is_err(),
            "MySQL {data_type} must reject text because the grid value is stored as spatial bytes"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_spatial_grid_refusal_preserves_native_bytes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mysql::Mysql;

    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await
        .unwrap();
    let connection = drivers_mysql::MysqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(3306).await.unwrap(),
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE spatial_grid_contract (
                id INT PRIMARY KEY,
                shape GEOMETRY NOT NULL,
                point_value POINT NOT NULL,
                area_value MULTIPOLYGON NOT NULL
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO spatial_grid_contract VALUES
                (1, ST_GeomFromText('POINT(1 2)'), ST_GeomFromText('POINT(3 4)'),
                    ST_GeomFromText('MULTIPOLYGON(((0 0,0 1,1 1,1 0,0 0)))')),
                (2, ST_GeomFromText('POINT(8 9)'), ST_GeomFromText('POINT(10 11)'),
                    ST_GeomFromText('MULTIPOLYGON(((2 2,2 3,3 3,3 2,2 2)))'))",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "spatial_grid_contract").await.unwrap();
    for (name, expected_type) in [
        ("shape", "geometry"),
        ("point_value", "point"),
        ("area_value", "multipolygon"),
    ] {
        let index = columns.iter().position(|column| column.name == name).unwrap();
        assert_eq!(columns[index].data_type.to_ascii_lowercase(), expected_type);
        assert!(
            parse_input_for_driver("POINT(9 9)", Some(&columns[index]), "mysql").is_err(),
            "{expected_type} must remain a read-only spatial edit"
        );
    }

    let oracle_sql = "SELECT id,
            ST_GeometryType(shape), ST_AsText(shape), HEX(shape),
            ST_GeometryType(point_value), ST_AsText(point_value), HEX(point_value),
            ST_GeometryType(area_value), ST_AsText(area_value), HEX(area_value)
        FROM spatial_grid_contract ORDER BY id";
    let before = connection.query(oracle_sql).await.unwrap();
    assert_eq!(before.rows.len(), 2);
    assert_eq!(before.rows[0][0], Value::Int(1));
    assert_eq!(before.rows[0][1], Value::Text("POINT".into()));
    assert_eq!(before.rows[0][2], Value::Text("POINT(1 2)".into()));
    assert_eq!(before.rows[0][4], Value::Text("POINT".into()));
    assert_eq!(before.rows[0][5], Value::Text("POINT(3 4)".into()));
    assert_eq!(before.rows[0][7], Value::Text("MULTIPOLYGON".into()));
    assert!(matches!(&before.rows[0][9], Value::Text(hex) if !hex.is_empty()));

    let after = connection.query(oracle_sql).await.unwrap();
    assert_eq!(
        after.rows, before.rows,
        "refused spatial edits must preserve native bytes, values and row identity"
    );
}
