use crate::runtime::Tasks;

/// `Tasks` bound to the current test runtime.
///
/// A test already runs inside `#[tokio::test]`, so taking the ambient
/// handle here is the one place it is correct.
#[expect(
    clippy::disallowed_methods,
    reason = "a test is already inside its own runtime; production code takes the handle from AppRuntime"
)]
pub(crate) fn paused_tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}

pub(crate) fn saved_connection(id: uuid::Uuid) -> tablepro_storage::SavedConnection {
    tablepro_storage::SavedConnection {
        id,
        name: "Prod".to_owned(),
        driver_id: "fake".to_owned(),
        host: "db.example.com".to_owned(),
        port: 5432,
        database: "shop".to_owned(),
        username: "app".to_owned(),
        tls: tablepro_core::TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        query_timeout_secs: None,
        masking_rules: Vec::new(),
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}
