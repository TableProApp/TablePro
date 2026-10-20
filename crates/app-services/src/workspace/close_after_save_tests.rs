use super::CloseAfterSave;
use uuid::Uuid;

#[test]
fn duplicate_save_completion_cannot_close_a_tab_twice() {
    let tab = Uuid::new_v4();
    let mut pending = CloseAfterSave::default();
    pending.begin(tab, 2);

    assert!(!pending.complete(&tab));
    assert_eq!(pending.remaining(&tab), Some(1));
    assert!(pending.complete(&tab));
    assert!(!pending.complete(&tab));
    assert!(pending.remaining(&tab).is_none());
}

#[test]
fn late_save_completion_cannot_consume_another_tabs_close_intent() {
    let closed_tab = Uuid::new_v4();
    let replacement_tab = Uuid::new_v4();
    let mut pending = CloseAfterSave::default();
    pending.begin(replacement_tab, 1);

    assert!(!pending.complete(&closed_tab));
    assert_eq!(pending.remaining(&replacement_tab), Some(1));
}
