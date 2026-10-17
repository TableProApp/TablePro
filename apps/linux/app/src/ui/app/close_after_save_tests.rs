use std::collections::HashMap;

use super::dec_close_after_save;
use uuid::Uuid;

#[test]
fn duplicate_save_completion_cannot_close_a_tab_twice() {
    let tab = Uuid::new_v4();
    let mut pending = HashMap::from([(tab, 2)]);

    assert!(!dec_close_after_save(&mut pending, &tab));
    assert_eq!(pending.get(&tab), Some(&1));
    assert!(dec_close_after_save(&mut pending, &tab));
    assert!(!dec_close_after_save(&mut pending, &tab));
    assert!(!pending.contains_key(&tab));
}

#[test]
fn late_save_completion_cannot_consume_another_tabs_close_intent() {
    let closed_tab = Uuid::new_v4();
    let replacement_tab = Uuid::new_v4();
    let mut pending = HashMap::from([(replacement_tab, 1)]);

    assert!(!dec_close_after_save(&mut pending, &closed_tab));
    assert_eq!(pending.get(&replacement_tab), Some(&1));
}
