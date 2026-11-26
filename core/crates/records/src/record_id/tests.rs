use serde_json::Value;
use uuid::Uuid;

use super::*;
use crate::envelope::SecretKind;

const CONNECTION: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";

fn uuid(text: &str) -> Uuid {
    Uuid::try_parse(text).expect("a UUID")
}

fn text<'a>(row: &'a Value, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str)
}

// Printed by the Mac's own `IdentityPath` and `TableScope` under Foundation, the way `FavoriteTablesStorage`,
// `FavoriteDatabasesStorage`, `TableFolderItemKey` and `ColumnLayoutPersister` name their records.
#[test]
fn every_derived_id_matches_the_mac_byte_for_byte() {
    let rows: Vec<Value> = serde_json::from_str(include_str!("../../fixtures/ids.json")).expect("the fixtures");
    assert!(rows.len() >= 15);
    for row in &rows {
        let connection = uuid(text(row, "connection").expect("a connection"));
        let database = text(row, "database");
        let schema = text(row, "schema");
        match text(row, "kind") {
            Some("favourite_table") => {
                let name = text(row, "name").expect("a name");
                let ids = favourite_table(connection, database, schema, name);
                assert_eq!(Some(ids.id.as_str()), text(row, "id"), "{row}");
                assert_eq!(ids.alias.as_deref(), text(row, "alias"), "{row}");
                assert_eq!(check(Kind::FavouriteTable, &ids.id), Ok(()));
            }
            Some("favourite_database") => {
                let id = favourite_database(connection, database.expect("a database"));
                assert_eq!(Some(id.as_str()), text(row, "id"), "{row}");
            }
            Some("table_folder_item") => {
                let name = text(row, "name").expect("a name");
                let id = table_folder_item(connection, database.expect("a database"), schema, name);
                assert_eq!(Some(id.as_str()), text(row, "id"), "{row}");
            }
            Some("column_layout") => {
                let table = text(row, "table").expect("a table");
                let category = column_layout_category(connection, database, schema, table);
                assert_eq!(Some(category.as_str()), text(row, "category"), "{row}");
                assert_eq!(column_layout_connection(&category), Some(connection));
            }
            other => panic!("unknown fixture kind {other:?}"),
        }
    }
}

// 0052, Ids per kind and Derived ids.
#[test]
fn the_adr_examples_come_out_as_written() {
    let connection = uuid(CONNECTION);

    assert_eq!(uuid_id(connection), CONNECTION);
    assert_eq!(
        favourite_table(connection, Some("shop"), Some("public"), "orders").id,
        "689915518ef07ed442508df9d8938612b7835aaef1759e217a9a1f0ec1527bfd"
    );
    assert_eq!(
        favourite_database(connection, "shop"),
        "cdf7849ae0e1748faad83bd8417480daac3b3b322224f4aeefd1977345b7f979"
    );
    assert_eq!(
        table_folder_item(connection, "shop", Some("public"), "orders"),
        "689915518ef07ed442508df9d8938612b7835aaef1759e217a9a1f0ec1527bfd"
    );
    assert_eq!(
        favourite_table(connection, Some("shop"), Some("public"), "a|b"),
        FavouriteTableId {
            id: "29fdd9a09689bcc75f08b364f5c921e2552ad3aa817a962716ad07112ca11f1e".to_owned(),
            alias: Some("14528d9753758a53d821e91074850e8944b2ffb58c31fb7bb145a98038f1df1d".to_owned()),
        }
    );
    assert_eq!(
        column_layout_category(connection, Some("shop"), Some("public"), "orders"),
        "columnLayout.6F1C2A9E%2D0B4D%2D4C8E%2D9A51%2D3D7E2B1F0C44.shop.public.orders"
    );
    assert_eq!(
        envelope_id(Kind::Connection, CONNECTION, &SecretKind::SshKeyPassphrase),
        "connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/ssh_key_passphrase"
    );
    assert_eq!(
        envelope_id(Kind::MacosSettings, "ai", &SecretKind::AiKey("A1".to_owned())),
        "macos_settings/ai/ai_key.A1"
    );
}

#[test]
fn a_uuid_id_is_upper_case_and_nothing_else_is_read_as_one() {
    let lower = CONNECTION.to_lowercase();

    assert_eq!(parse_uuid(CONNECTION), Some(uuid(CONNECTION)));
    assert_eq!(parse_uuid(&lower), None);
    assert_eq!(parse_uuid("6F1C2A9E0B4D4C8E9A513D7E2B1F0C44"), None);
    assert_eq!(parse_uuid("{6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44}"), None);
    assert_eq!(check(Kind::Connection, CONNECTION), Ok(()));
    assert_eq!(
        check(Kind::Connection, &lower),
        Err(IdError::Form { kind: Kind::Connection })
    );
}

#[test]
fn a_history_entry_takes_a_random_v4_id() {
    assert_eq!(
        check(Kind::HistoryEntry, "07D0575D-F499-463A-AB54-2852D631B0B4"),
        Ok(())
    );
    assert!(check(Kind::HistoryEntry, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8").is_err());
    let fresh = new_id();
    assert_eq!(check(Kind::HistoryEntry, &fresh), Ok(()));
}

#[test]
fn record_ids_are_one_to_255_utf16_units_without_nul() {
    assert!(well_formed("a"));
    assert!(!well_formed(""));
    assert!(!well_formed("a\0b"));
    assert!(well_formed(&"é".repeat(255)));
    assert!(!well_formed(&"😀".repeat(128)));
    assert!(well_formed(&"😀".repeat(127)));
    assert_eq!(check(Kind::LibraryConnection, "Some Client Id"), Ok(()));
}

#[test]
fn a_long_settings_category_takes_the_digest_form_the_mac_computes() {
    let category = format!("columnLayout.{}", "a".repeat(260));
    let id = shortened(Kind::MacosSettings, category.clone());

    assert_eq!(id, format!("sha256-{}", sha256_hex(&category)));
    assert_eq!(check(Kind::MacosSettings, &id), Ok(()));
    // 9 for `Settings_` and 246 more fit; one more does not.
    let fits = "x".repeat(246);
    assert_eq!(shortened(Kind::MacosSettings, fits.clone()), fits);
    assert!(shortened(Kind::MacosSettings, "x".repeat(247)).starts_with(DIGEST_PREFIX));
    // A kind CloudKit does not carry has no prefix.
    assert_eq!(shortened(Kind::LinuxSettings, "x".repeat(255)), "x".repeat(255));
}

#[test]
fn settings_ids_are_the_categories_the_registry_names() {
    for category in ["editor", "dataGrid", "customSlashCommands", "theme.user.1a2b3c4d"] {
        assert_eq!(check(Kind::MacosSettings, category), Ok(()), "{category}");
    }
    let layout = column_layout_category(uuid(CONNECTION), Some("shop"), None, "orders");
    assert_eq!(check(Kind::MacosSettings, &layout), Ok(()));
    for category in [
        "sync",
        "mcp",
        "Editor",
        "theme.",
        "theme.a..b",
        "theme.a/b",
        "columnLayout.x",
    ] {
        assert!(check(Kind::MacosSettings, category).is_err(), "{category}");
    }
    assert!(check(Kind::LinuxSettings, "editor").is_err());
    assert_eq!(theme_category("user.1a2b3c4d").as_deref(), Some("theme.user.1a2b3c4d"));
    assert_eq!(theme_category(&"a".repeat(129)), None);
}

#[test]
fn an_envelope_id_reads_back_its_parent_and_secret() {
    let id = format!("connection/{CONNECTION}/plugin.service/account");
    assert_eq!(parse_envelope_id(&id), None);
    let id = format!("library_connection/{}/password", CONNECTION.to_lowercase());
    assert_eq!(
        parse_envelope_id(&id),
        Some((
            Kind::LibraryConnection,
            CONNECTION.to_lowercase().as_str(),
            SecretKind::Password
        ))
    );
    assert_eq!(
        parse_envelope_id("macos_settings/ai/ai_key.7C1A"),
        Some((Kind::MacosSettings, "ai", SecretKind::AiKey("7C1A".to_owned())))
    );
    assert_eq!(parse_envelope_id(&format!("connection/{CONNECTION}/ai_key.A")), None);
    assert_eq!(parse_envelope_id(&format!("group/{CONNECTION}/password")), None);
    assert_eq!(
        check(Kind::SecretEnvelope, &format!("ssh_profile/{CONNECTION}/ssh_password")),
        Ok(())
    );
}

#[test]
fn the_key_object_examples_read_and_write_back() {
    let examples = [
        (Kind::KeyAccount, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/1"),
        (Kind::KeyAccount, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/4"),
        (
            Kind::KeyDevice,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
        ),
        (Kind::KeyRecovery, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/4"),
        (
            Kind::KeyReset,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78",
        ),
        (
            Kind::KeyCancel,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78",
        ),
        (Kind::KeyRequest, "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357"),
        (Kind::KeySas, "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357/nonce"),
        (Kind::KeyVersion, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/history/2"),
        (Kind::KeyVersion, "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5"),
        (
            Kind::KeyWrap,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/account/4/device/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
        ),
        (
            Kind::KeyWrap,
            "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5/account/019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2",
        ),
        (Kind::KeyRing, "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5"),
        (Kind::KeyMember, "019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2"),
    ];
    for (kind, id) in examples {
        let parsed = KeyObjectId::parse(kind, id).unwrap_or_else(|| panic!("{kind} {id}"));
        assert_eq!(parsed.kind(), kind);
        assert_eq!(parsed.to_string(), id);
        assert_eq!(check(kind, id), Ok(()));
    }
}

#[test]
fn a_key_object_id_off_its_grammar_is_refused() {
    let account = "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8";
    let device = "DB09A1EA-A519-42FF-94F3-CEEE6232F1C2";
    let refused = [
        (Kind::KeyAccount, format!("{account}/0")),
        (Kind::KeyAccount, format!("{account}/04")),
        (Kind::KeyAccount, format!("{account}/2147483648")),
        (Kind::KeyAccount, format!("{}/1", account.to_lowercase())),
        (Kind::KeyAccount, format!("{account}/1/2")),
        (Kind::KeySas, format!("{account}/accept")),
        (Kind::KeyVersion, format!("{account}/account/1")),
        (Kind::KeyVersion, format!("{account}/Team/1")),
        (Kind::KeyRing, format!("{account}/trust/1")),
        (Kind::KeyWrap, format!("{account}/team/5/device/{device}/2")),
        (Kind::KeyWrap, format!("{account}/account/4/account/{device}/4")),
        (Kind::KeyWrap, format!("{account}/account/4/device/{device}/3")),
    ];
    for (kind, id) in refused {
        assert_eq!(KeyObjectId::parse(kind, &id), None, "{kind} {id}");
        assert_eq!(check(kind, &id), Err(IdError::Form { kind }), "{kind} {id}");
    }
    assert!(KeyObjectId::parse(Kind::KeyAccount, &format!("{account}/2147483647")).is_some());
}

#[test]
fn a_personal_key_object_binds_to_the_account_its_id_names_and_a_team_one_to_its_signer() {
    let account = uuid("019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8");
    let team = "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63";
    let personal = KeyObjectId::parse(Kind::KeyVersion, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/personal/3");
    let teams = KeyObjectId::parse(Kind::KeyVersion, &format!("{team}/team/5"));

    assert_eq!(personal.and_then(|id| id.bound_account()), Some(account));
    assert_eq!(teams.and_then(|id| id.bound_account()), None);
    assert_eq!(
        teams.map(|id| match id {
            KeyObjectId::Version { purpose, .. } => purpose.scope(),
            _ => crate::kind::Scope::Personal,
        }),
        Some(crate::kind::Scope::Team)
    );
}

#[test]
fn a_team_record_keeps_a_stored_id_in_its_case_and_a_new_one_is_lower_case() {
    let entity = uuid(CONNECTION);
    let stored = ["0B0C", "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44"];

    assert_eq!(library_id(entity, stored), CONNECTION);
    assert_eq!(library_id(entity, ["other"]), CONNECTION.to_lowercase());
    assert!(library_ids_match(CONNECTION, &CONNECTION.to_lowercase()));
    assert!(!library_ids_match("", ""));
}
