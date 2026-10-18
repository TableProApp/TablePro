use std::error::Error;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretKind, SecretLookup, SecretVault};
use tablepro_storage::SecretStore;
use uuid::Uuid;

type TestResult = Result<(), Box<dyn Error>>;

/// A schema of its own, so a run never touches the developer's real
/// TablePro items.
fn store() -> SecretStore {
    SecretStore::new(format!("app.tablepro.TablePro.Test.{}", Uuid::new_v4().simple()))
}

#[tokio::test]
#[ignore = "requires a Secret Service"]
async fn store_load_relabel_round_trip() -> TestResult {
    let store = store();
    let id = Uuid::new_v4();

    store
        .store(id, SecretKind::DatabasePassword, &SecretString::from("s3cret"), "first")
        .await?;
    let found = store.load(id, SecretKind::DatabasePassword).await?;
    store.relabel(id, SecretKind::DatabasePassword, "second").await?;
    let after_relabel = store.load(id, SecretKind::DatabasePassword).await?;
    store.delete_connection(id).await?;

    let SecretLookup::Found(secret) = found else {
        return Err("the secret was not stored".into());
    };
    assert_eq!(secret.expose_secret(), "s3cret");
    // A relabel must not disturb the secret itself.
    let SecretLookup::Found(secret) = after_relabel else {
        return Err("the relabel lost the secret".into());
    };
    assert_eq!(secret.expose_secret(), "s3cret");
    Ok(())
}

#[tokio::test]
#[ignore = "requires a Secret Service"]
async fn delete_connection_removes_all_three_kinds() -> TestResult {
    let store = store();
    let id = Uuid::new_v4();
    for kind in SecretKind::ALL {
        store.store(id, kind, &SecretString::from("x"), "label").await?;
    }

    store.delete_connection(id).await?;

    for kind in SecretKind::ALL {
        assert!(!store.load(id, kind).await?.is_stored(), "{kind:?} survived the delete");
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires a Secret Service"]
async fn load_missing_is_not_stored() -> TestResult {
    let store = store();

    let looked_up = store.load(Uuid::new_v4(), SecretKind::DatabasePassword).await?;

    // A connection with no saved password is normal, not an error.
    assert!(!looked_up.is_stored());
    Ok(())
}

#[tokio::test]
#[ignore = "requires a Secret Service"]
async fn two_schemas_do_not_see_each_other() -> TestResult {
    let id = Uuid::new_v4();
    let installed = store();
    let devel = store();

    installed
        .store(id, SecretKind::DatabasePassword, &SecretString::from("installed"), "l")
        .await?;
    let from_devel = devel.load(id, SecretKind::DatabasePassword).await?;
    installed.delete_connection(id).await?;

    assert!(!from_devel.is_stored(), "a development build read an installed secret");
    Ok(())
}
