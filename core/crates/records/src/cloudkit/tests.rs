use std::collections::{BTreeMap, BTreeSet};

use serde_json::json;

use super::project::camel;
use super::*;
use crate::kind::Kind;
use crate::schema::{Class, schema};

// `apple/scripts/export-cloudkit-schema.sh` writes this copy beside the Swift tests' snapshot.
const PRODUCTION: &str = include_str!("../../fixtures/production-schema.ckdb");

// A Linux source archive holds no `apple/`, so there the copy has nothing to match.
#[test]
fn the_copy_matches_the_snapshot_the_swift_tests_read() {
    let snapshot =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../apple/CloudKit/production-schema.ckdb");
    let Ok(swift) = std::fs::read_to_string(&snapshot) else {
        return;
    };
    assert_eq!(
        swift, PRODUCTION,
        "run apple/scripts/export-cloudkit-schema.sh to refresh both"
    );
}

// `RECORD TYPE <name> ( ... );` blocks, each field as its name and type; CloudKit's own `"___"` fields left out.
fn production() -> BTreeMap<String, BTreeMap<String, String>> {
    let mut types = BTreeMap::new();
    for block in PRODUCTION.split("RECORD TYPE ").skip(1) {
        let Some((name, body)) = block.split_once('(') else {
            continue;
        };
        let body = body.split(");").next().unwrap_or_default();
        let fields = body
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('"') && !line.starts_with("GRANT"))
            .filter_map(|line| {
                let mut words = line.split_whitespace();
                Some((words.next()?.to_owned(), words.next()?.trim_end_matches(',').to_owned()))
            })
            .collect();
        types.insert(name.trim().to_owned(), fields);
    }
    types
}

#[test]
fn the_snapshot_parses_into_known_record_types() {
    let production = production();

    assert!(
        production
            .get("Connection")
            .is_some_and(|fields| fields.contains_key("connectionId"))
    );
    assert_eq!(
        production
            .get("Connection")
            .and_then(|fields| fields.get("tagIds"))
            .map(String::as_str),
        Some("LIST<STRING>")
    );
}

// The Rust twin of `ProductionSchemaParityTests`: what the registry writes is deployed, and what it holds back is not.
#[test]
fn the_registry_matches_the_production_schema() {
    let production = production();
    for record_type in RECORD_TYPES {
        let deployed = production.get(record_type.name);
        assert_eq!(deployed.is_some(), record_type.deployed, "{}", record_type.name);
        let Some(deployed) = deployed else {
            continue;
        };
        for field in record_type.fields {
            match deployed.get(field.name) {
                Some(ty) => {
                    assert!(field.deployed, "{}.{} is in Production", record_type.name, field.name);
                    assert_eq!(ty, field.ty.schema_name(), "{}.{}", record_type.name, field.name);
                }
                None => assert!(
                    !field.deployed,
                    "{}.{} is not in Production",
                    record_type.name, field.name
                ),
            }
        }
        for name in deployed.keys() {
            assert!(
                record_type.field(name).is_some(),
                "{}.{name} is in Production and the registry does not declare it",
                record_type.name
            );
        }
    }
    for name in production.keys() {
        assert!(
            record_type_named(name).is_some() || RETIRED_RECORD_TYPES.contains(&name.as_str()),
            "{name} is in Production and neither registered nor retired"
        );
    }
}

// Every wire member of a kind iCloud carries rides in a CloudKit field, except TablePro Sync's own (0054: iCloud gains
// no field).
#[test]
fn the_projection_covers_every_wire_member_icloud_carries() {
    let service_only: BTreeMap<Kind, BTreeSet<&str>> = BTreeMap::from([
        (
            Kind::Connection,
            BTreeSet::from([
                "external_access",
                "credential_profile_id",
                "credential_reference",
                "auth_mode",
                "network_options",
            ]),
        ),
        (Kind::SshProfile, BTreeSet::new()),
    ]);
    for record_type in RECORD_TYPES {
        let carried: BTreeSet<&str> = record_type
            .fields
            .iter()
            .filter_map(|field| match field.carries {
                Carries::Wire(key) => Some(key),
                _ => None,
            })
            .collect();
        let schema = schema(record_type.kind);
        for key in &carried {
            assert!(schema.field(key).is_some(), "{}: {key}", record_type.name);
        }
        let uncarried: BTreeSet<&str> = schema
            .fields
            .iter()
            .filter(|field| field.class.is_pushed())
            .map(|field| field.key)
            .filter(|key| !carried.contains(key))
            .collect();
        let expected = service_only.get(&record_type.kind).cloned().unwrap_or_default();
        assert_eq!(uncarried, expected, "{}", record_type.name);
    }
}

#[test]
fn a_json_fields_members_are_the_wire_names_in_camel_case() {
    assert_eq!(camel("private_key_path"), "privateKeyPath");
    assert_eq!(camel("ssh_profile_id"), "sshProfileId");
    assert_eq!(camel("host"), "host");
    for record_type in RECORD_TYPES {
        for field in record_type.fields {
            if let Carries::Wire(key) = field.carries
                && field.ty != CloudType::Bytes
            {
                assert_eq!(camel(key), field.name, "{}", record_type.name);
            }
        }
    }
}

fn mac_connection() -> CloudFields {
    let ssh = json!({
        "agentSocketPath": "",
        "authMethod": "Private Key",
        "enabled": true,
        "host": "bastion",
        "jumpHosts": [{"authMethod": "SSH Agent", "host": "edge", "id": "9E5B6C0B-1C11-4C5B-9C8B-8E3C2C1A0B01", "privateKeyPath": "", "username": "a"}],
        "port": 22,
        "privateKeyPath": "~/.ssh/id_ed25519",
        "remoteFileAccess": "readOnlyCopy",
        "remoteFilePath": "",
        "totpAlgorithm": "SHA1",
        "totpDigits": 6,
        "totpMode": "none",
        "totpPeriod": 30,
        "username": "ops"
    });
    let ssl = json!({"caCertificatePath": "~/certs/ca.pem", "clientCertificatePath": "", "clientKeyPath": "", "mode": "Verify Identity"});
    let extra = json!({"connectTimeoutSeconds": "30", "mongoAuthSource": "admin"});
    BTreeMap::from([
        (
            "connectionId".to_owned(),
            CloudValue::Text("6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned()),
        ),
        ("name".to_owned(), CloudValue::Text("Shop".to_owned())),
        ("host".to_owned(), CloudValue::Text("db.internal".to_owned())),
        ("port".to_owned(), CloudValue::Int64(5432)),
        ("database".to_owned(), CloudValue::Text("shop".to_owned())),
        ("username".to_owned(), CloudValue::Text("app".to_owned())),
        ("type".to_owned(), CloudValue::Text("PostgreSQL".to_owned())),
        ("color".to_owned(), CloudValue::Text("Blue".to_owned())),
        ("colorTag".to_owned(), CloudValue::Text("Blue".to_owned())),
        ("safeModeLevel".to_owned(), CloudValue::Text("alertFull".to_owned())),
        ("isReadOnly".to_owned(), CloudValue::Int64(0)),
        ("sortOrder".to_owned(), CloudValue::Int64(3)),
        (
            "groupId".to_owned(),
            CloudValue::Text("E6C12C96-3CBD-4A0E-9F41-E36B47F35D84".to_owned()),
        ),
        (
            "tagId".to_owned(),
            CloudValue::Text("84BC7D00-A144-4C18-80C0-A11C6070D4F9".to_owned()),
        ),
        (
            "tagIds".to_owned(),
            CloudValue::TextList(vec!["84BC7D00-A144-4C18-80C0-A11C6070D4F9".to_owned()]),
        ),
        ("queryTimeoutSeconds".to_owned(), CloudValue::Int64(60)),
        ("sshConfigJson".to_owned(), CloudValue::Bytes(mac_json_bytes(&ssh))),
        ("sslConfigJson".to_owned(), CloudValue::Bytes(mac_json_bytes(&ssl))),
        (
            "additionalFieldsJson".to_owned(),
            CloudValue::Bytes(mac_json_bytes(&extra)),
        ),
        ("aiPolicy".to_owned(), CloudValue::Text("askEachTime".to_owned())),
        (
            "aiAlwaysAllowedTools".to_owned(),
            CloudValue::TextList(vec!["describe_table".to_owned()]),
        ),
        ("isFavorite".to_owned(), CloudValue::Int64(1)),
        ("modifiedAtLocal".to_owned(), CloudValue::Timestamp(1_700_000_000_000)),
        ("schemaVersion".to_owned(), CloudValue::Int64(1)),
    ])
}

#[test]
fn a_mac_connection_reads_as_its_wire_record() {
    let record = to_wire(
        "Connection",
        "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
        &mac_connection(),
    )
    .expect("the record reads");

    assert_eq!(record.kind, Kind::Connection);
    assert_eq!(record.record_id, "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44");
    assert_eq!(
        record.fields,
        json!({
            "name": "Shop",
            "host": "db.internal",
            "port": 5432,
            "database": "shop",
            "username": "app",
            "type": "PostgreSQL",
            "color": "Blue",
            "safe_mode_level": "alertFull",
            "sort_order": 3,
            "group_id": "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84",
            "tag_ids": ["84BC7D00-A144-4C18-80C0-A11C6070D4F9"],
            "query_timeout_seconds": 60,
            "ssh_config": {
                "agent_socket_path": "",
                "auth_method": "Private Key",
                "enabled": true,
                "host": "bastion",
                "jump_hosts": [{"auth_method": "SSH Agent", "host": "edge", "id": "9E5B6C0B-1C11-4C5B-9C8B-8E3C2C1A0B01", "private_key_path": "", "username": "a"}],
                "port": 22,
                "private_key_path": "~/.ssh/id_ed25519",
                "remote_file_access": "readOnlyCopy",
                "remote_file_path": "",
                "totp_algorithm": "SHA1",
                "totp_digits": 6,
                "totp_mode": "none",
                "totp_period": 30,
                "username": "ops"
            },
            "ssl_config": {"ca_certificate_path": "~/certs/ca.pem", "client_certificate_path": "", "client_key_path": "", "mode": "Verify Identity"},
            "additional_fields": [{"id": "connectTimeoutSeconds", "value": "30"}, {"id": "mongoAuthSource", "value": "admin"}],
            "ai_policy": "askEachTime",
            "ai_always_allowed_tools": ["describe_table"],
            "is_favorite": true,
            "schema_version": 1
        })
    );
}

// Written back, each field comes out as the Mac's mapper writes it, so a Mac on the Swift engine sees no edit.
#[test]
fn a_wire_connection_writes_the_fields_the_mac_wrote() {
    let fields = mac_connection();
    let record = to_wire("Connection", "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &fields).expect("reads");
    let saved = from_wire(Kind::Connection, &record.record_id, &record.fields, 1_800_000_000_000)
        .expect("writes")
        .expect("a save");

    for (name, value) in &fields {
        let expected = match name.as_str() {
            "modifiedAtLocal" => CloudValue::Timestamp(1_800_000_000_000),
            _ => value.clone(),
        };
        assert_eq!(saved.get(name.as_str()), Some(&Some(expected)), "{name}");
    }
    for cleared in [
        "iconName",
        "aiRules",
        "redisDatabase",
        "startupCommands",
        "sshProfileId",
        "sshRouteJson",
    ] {
        assert_eq!(saved.get(cleared), Some(&None), "{cleared}");
    }
    for held_back in ["projectId", "sshEnabled", "sslEnabled"] {
        assert!(!saved.contains_key(held_back), "{held_back}");
    }
}

#[test]
fn members_only_tablepro_sync_carries_stay_out_of_icloud() {
    let wire = json!({
        "name": "n",
        "ssh_config": {"host": "h", "passphrase_stored": true},
        "ssl_config": {"mode": "Required", "server_name": "db.example"},
        "external_access": "readWrite",
        "project_id": "CBCAF15E-97D4-4B75-8D5D-01D586CADC97"
    });
    let saved = from_wire(Kind::Connection, "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &wire, 0)
        .expect("writes")
        .expect("a save");
    let bytes = |name: &str| match saved.get(name) {
        Some(Some(CloudValue::Bytes(bytes))) => String::from_utf8(bytes.clone()).expect("text"),
        other => panic!("{name}: {other:?}"),
    };

    assert_eq!(bytes("sshConfigJson"), r#"{"host":"h"}"#);
    assert_eq!(bytes("sslConfigJson"), r#"{"mode":"Required"}"#);
    assert!(!saved.contains_key("projectId"));
    assert!(saved.keys().all(|name| !name.contains("external")));
}

#[test]
fn legacy_fields_fill_in_for_missing_current_ones_and_are_written_for_older_readers() {
    let older = BTreeMap::from([
        ("name".to_owned(), CloudValue::Text("Old".to_owned())),
        ("colorTag".to_owned(), CloudValue::Text("#FF3B30".to_owned())),
        ("isReadOnly".to_owned(), CloudValue::Int64(1)),
        (
            "tagId".to_owned(),
            CloudValue::Text("84BC7D00-A144-4C18-80C0-A11C6070D4F9".to_owned()),
        ),
    ]);
    let record = to_wire("Connection", "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &older).expect("reads");

    assert_eq!(
        record.fields,
        json!({
            "name": "Old",
            "color": "Red",
            "safe_mode_level": "readOnly",
            "tag_ids": ["84BC7D00-A144-4C18-80C0-A11C6070D4F9"]
        })
    );
    let saved = from_wire(Kind::Connection, &record.record_id, &record.fields, 0)
        .expect("writes")
        .expect("a save");
    assert_eq!(saved.get("isReadOnly"), Some(&Some(CloudValue::Int64(1))));
    assert_eq!(saved.get("colorTag"), Some(&Some(CloudValue::Text("Red".to_owned()))));
    assert_eq!(
        saved.get("tagId"),
        Some(&Some(CloudValue::Text(
            "84BC7D00-A144-4C18-80C0-A11C6070D4F9".to_owned()
        )))
    );
}

#[test]
fn a_column_layout_goes_by_column_on_the_wire_and_as_the_macs_map_on_icloud() {
    let category = "columnLayout.6F1C2A9E%2D0B4D%2D4C8E%2D9A51%2D3D7E2B1F0C44.shop.public.users";
    let layout = json!({"columnOrder": ["id", "password"], "columnWidths": {"id": 80, "password": 120.5}});
    let fields = BTreeMap::from([
        ("category".to_owned(), CloudValue::Text(category.to_owned())),
        ("settingsJson".to_owned(), CloudValue::Bytes(mac_json_bytes(&layout))),
        ("schemaVersion".to_owned(), CloudValue::Int64(1)),
    ]);
    let name = record_name(Kind::MacosSettings, category).expect("a name");
    let record = to_wire("AppSettings", &name, &fields).expect("reads");

    assert_eq!(
        record.fields["options"],
        json!({"columnOrder": ["id", "password"], "columnWidths": [{"id": "id", "value": 80}, {"id": "password", "value": 120.5}]})
    );
    assert_eq!(crate::secret_key::first_secret_key(&record.fields), None);
    let saved = from_wire(Kind::MacosSettings, category, &record.fields, 0)
        .expect("writes")
        .expect("a save");
    assert_eq!(
        saved.get("settingsJson"),
        Some(&Some(CloudValue::Bytes(mac_json_bytes(&layout))))
    );
}

#[test]
fn a_long_category_is_named_by_its_digest_and_read_back_from_its_field() {
    let category = format!("columnLayout.{}.db..t", "A".repeat(300));
    let name = record_name(Kind::MacosSettings, &category).expect("a name");

    assert!(name.starts_with("Settings_sha256-"));
    assert_eq!(name.encode_utf16().count(), "Settings_sha256-".len() + 64);
    let fields = BTreeMap::from([
        ("category".to_owned(), CloudValue::Text(category.clone())),
        ("settingsJson".to_owned(), CloudValue::Bytes(b"{}".to_vec())),
    ]);
    let record = to_wire("AppSettings", &name, &fields).expect("reads");
    assert_eq!(record.fields["category"], json!(category));
}

#[test]
fn record_names_split_on_the_longest_prefix() {
    let (record_type, id) = parse_record_name("FavoriteFolder_380CB783-4B26-48F3-8F84-1468967A9FA3").expect("a name");
    assert_eq!(
        (record_type.name, id),
        ("SQLFavoriteFolder", "380CB783-4B26-48F3-8F84-1468967A9FA3")
    );
    let (record_type, _) = parse_record_name("Favorite_E9BFE8BE-525F-4F8A-9E9C-F795A5F09A8B").expect("a name");
    assert_eq!(record_type.name, "SQLFavorite");
    assert_eq!(parse_record_name("History_x"), None);
    assert_eq!(record_name(Kind::LibraryFolder, "x"), None);
}

#[test]
fn a_record_that_does_not_read_is_refused_by_its_code() {
    let refused = |error: ProjectionError| error.code();

    assert_eq!(
        to_wire("QueryHistory", "x", &BTreeMap::new()).map_err(refused),
        Err("records.unknown_record_type")
    );
    assert_eq!(
        to_wire(
            "Connection",
            "Group_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
            &BTreeMap::new()
        )
        .map_err(refused),
        Err("records.bad_record_name")
    );
    assert_eq!(
        to_wire(
            "Connection",
            "Connection_6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44",
            &BTreeMap::new()
        )
        .map_err(refused),
        Err("records.bad_record_id")
    );
    let bad_port = BTreeMap::from([("port".to_owned(), CloudValue::Text("5432".to_owned()))]);
    assert_eq!(
        to_wire(
            "Connection",
            "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
            &bad_port
        )
        .map_err(refused),
        Err("records.bad_field")
    );
}

#[test]
fn a_wire_value_of_the_wrong_shape_is_refused_rather_than_cleared() {
    for wire in [
        json!({"name": "n", "port": "5432"}),
        json!({"name": "n", "tag_ids": [123]}),
        json!({"name": "n", "additional_fields": [{"id": "mongoAuthSource"}]}),
        json!({"name": "n", "ssh_config": {"jump_hosts": [{"port": "22"}]}}),
    ] {
        assert_eq!(
            from_wire(Kind::Connection, "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &wire, 0).map_err(|error| error.code()),
            Err("records.bad_field"),
            "{wire}"
        );
    }
}

#[test]
fn a_cloudkit_field_of_the_wrong_shape_makes_the_record_unreadable() {
    let fields = BTreeMap::from([(
        "sshConfigJson".to_owned(),
        CloudValue::Bytes(mac_json_bytes(&json!({"port": "22"}))),
    )]);

    assert_eq!(
        to_wire("Connection", "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &fields).map_err(|error| error.code()),
        Err("records.bad_field")
    );
}

#[test]
fn a_route_the_mac_cannot_decode_reads_as_none() {
    let fields = BTreeMap::from([
        ("name".to_owned(), CloudValue::Text("n".to_owned())),
        ("sshRouteJson".to_owned(), CloudValue::Bytes(b"not json".to_vec())),
    ]);
    let record = to_wire("Connection", "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44", &fields).expect("reads");

    assert_eq!(record.fields, json!({"name": "n"}));
}

#[test]
fn a_project_is_held_back_until_production_holds_it() {
    assert_eq!(
        from_wire(
            Kind::ConnectionProject,
            "CBCAF15E-97D4-4B75-8D5D-01D586CADC97",
            &json!({"name": "p"}),
            0
        ),
        Ok(None)
    );
    assert_eq!(prefix(Kind::ConnectionProject), "Project_");
    assert_eq!(schema(Kind::ConnectionProject).class("name"), Class::Inert);
}

#[test]
fn every_wire_record_read_from_icloud_passes_the_servers_checks() {
    let record = to_wire(
        "Connection",
        "Connection_6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
        &mac_connection(),
    )
    .expect("reads");

    assert_eq!(crate::limits::check(&record.fields), Ok(()));
    assert_eq!(record.fields["is_favorite"], json!(true));
}
