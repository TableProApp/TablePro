use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::json;
use tablepro_storage::{TeamLibraryItem, TeamLibraryKind};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::team_library::TeamItem;
use uuid::Uuid;

use super::*;

struct Toggle(AtomicBool);

impl SignInGuard for Toggle {
    fn holds(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

fn team(n: u128) -> TeamId {
    TeamId(Uuid::from_u128(n))
}

fn held(n: u128, role: Role) -> TeamLibraryTeam {
    TeamLibraryTeam {
        team: team(n),
        name: None,
        role: Some(role),
        writable: role != Role::Member,
        items: vec![TeamItem {
            item: TeamLibraryItem {
                kind: TeamLibraryKind::Query,
                id: "q1".to_owned(),
                fields: json!({"name": "Revenue", "query": "select 1"}),
            },
            updated_by: Some("Ada".to_owned()),
            updated_at_ms: Some(1),
        }],
    }
}

fn connection() -> TeamConnection {
    TeamConnection {
        id: Uuid::from_u128(9),
        settings: json!({"name": "Prod", "host": "db"}),
    }
}

fn code(error: SyncError) -> &'static str {
    error.code()
}

#[tokio::test]
async fn a_publish_after_the_sign_in_ended_is_refused_and_sends_nothing() {
    let sign_in = Arc::new(Toggle(AtomicBool::new(true)));
    let fake = FakeTeamLibrary::new(Arc::clone(&sign_in) as Arc<dyn SignInGuard>);
    fake.set_teams(vec![held(1, Role::Editor)]);
    fake.answer_publishes(TeamPublish {
        edits: 1,
        ..TeamPublish::default()
    });

    let first = fake.publish_team_connections(team(1), vec![connection()]).await;
    sign_in.0.store(false, Ordering::SeqCst);
    let second = fake.publish_team_connections(team(1), vec![connection()]).await;

    assert_eq!(first.unwrap().edits, 1);
    assert_eq!(code(second.unwrap_err()), "sync.team_library.signed_in_changed");
    assert_eq!(fake.calls().len(), 1);
    assert_eq!(
        code(fake.team_library().await.unwrap_err()),
        "sync.team_library.signed_in_changed"
    );
}

#[tokio::test]
async fn a_member_s_team_and_a_team_the_account_does_not_reach_refuse_a_publish() {
    let fake = FakeTeamLibrary::default();
    fake.set_teams(vec![held(1, Role::Member)]);

    let member = fake.publish_team_connections(team(1), vec![connection()]).await;
    let unknown = fake.remove_team_items(team(2), Vec::new()).await;

    assert_eq!(code(member.unwrap_err()), "sync.team_library.not_writable");
    assert_eq!(code(unknown.unwrap_err()), "sync.team_library.unknown_team");
    assert!(fake.calls().is_empty());
}

#[tokio::test]
async fn a_failed_delete_keeps_team_library_off_until_a_delete_succeeds() {
    let fake = FakeTeamLibrary::default();
    fake.set_teams(vec![held(1, Role::Owner)]);
    fake.fail_deletes(true);

    let failed = fake.delete_team_library_data().await;
    let while_pending = fake.team_library().await;
    fake.fail_deletes(false);
    fake.delete_team_library_data().await.unwrap();

    assert_eq!(code(failed.unwrap_err()), "sync.team_library.delete_failed");
    assert_eq!(code(while_pending.unwrap_err()), "sync.team_library.delete_pending");
    assert!(fake.team_library().await.unwrap().is_empty());
    assert!(fake.deleted());
}

#[tokio::test]
async fn a_sign_out_lists_discards_and_deletes_after_the_sign_in_ended() {
    let fake = FakeTeamLibrary::new(Arc::new(Toggle(AtomicBool::new(false))));

    let listed = fake.unsent_team_edits().await;
    fake.discard_team_edits(None).await.unwrap();
    fake.delete_team_library_data().await.unwrap();

    assert!(listed.unwrap().is_empty());
    assert_eq!(fake.calls(), [TeamLibraryCall::Discard(None), TeamLibraryCall::Delete]);
}

#[tokio::test]
async fn discarding_one_team_keeps_the_other_team_s_edits() {
    let fake = FakeTeamLibrary::default();
    let edit = |n| UnsentTeamEdit {
        team: team(n),
        item: TeamItemRef {
            kind: TeamLibraryKind::Folder,
            id: "f1".to_owned(),
        },
        name: Some("Shared".to_owned()),
        deletion: false,
        state: tablepro_sync::api::team_library::UnsentState::Pending,
    };
    fake.set_unsent(vec![edit(1), edit(2)]);

    fake.discard_team_edits(Some(team(1))).await.unwrap();
    let left = fake.unsent_team_edits().await.unwrap();
    fake.discard_team_edits(None).await.unwrap();

    assert_eq!(left, [edit(2)]);
    assert!(fake.unsent_team_edits().await.unwrap().is_empty());
}
