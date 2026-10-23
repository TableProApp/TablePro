use super::tests::page;
use super::*;
use tablepro_core::Value;

fn byte_page(bytes: usize) -> Arc<QueryResult> {
    let mut result = page(&["payload"], &[]).as_ref().clone();
    result.columns[0].data_type = "BYTEA".into();
    result.rows = vec![vec![Value::Bytes(vec![7; bytes])]];
    Arc::new(result)
}

#[test]
fn sustained_streams_keep_four_pages_and_release_every_eviction() {
    let mut cache = StreamPageCache::default();
    let mut retired = VecDeque::new();
    for index in 0..20_000 {
        let result = page(&["id"], &[index]);
        retired.push_back(Arc::downgrade(&result));
        cache.append(index as u64, result).unwrap();
        assert!(cache.pages().len() <= 4);
        if retired.len() > 4 {
            assert!(retired.pop_front().unwrap().upgrade().is_none());
        }
    }
    let snapshot = cache.snapshot(StreamTerminal::Complete, None);
    assert_eq!(snapshot.total_rows, 20_000);
    assert_eq!(snapshot.page_indices, vec![19_996, 19_997, 19_998, 19_999]);
    drop(snapshot);
    drop(cache);
    assert!(retired.iter().all(|result| result.upgrade().is_none()));
}

#[test]
fn snapshots_share_payloads_and_release_them_after_the_last_owner() {
    let mut cache = StreamPageCache::default();
    let result = page(&["id"], &[1]);
    let weak = Arc::downgrade(&result);
    cache.append(0, result).unwrap();
    let first = cache.snapshot(StreamTerminal::Loading, None);
    let second = cache.snapshot(StreamTerminal::Complete, None);
    assert!(Arc::ptr_eq(&first.pages[0], &second.pages[0]));
    assert!(Arc::ptr_eq(&first.pages[0], &cache.pages()[0].1));
    for index in 1..5 {
        cache.append(index, page(&["id"], &[index as i64])).unwrap();
    }
    assert_eq!(cache.first_page(), 1);
    drop(first);
    assert!(weak.upgrade().is_some());
    drop(second);
    assert!(weak.upgrade().is_none());
}

#[test]
fn exactly_sixty_four_mib_is_retained_and_the_next_row_evicts_an_old_page() {
    let overhead = byte_page(0).estimated_row_bytes();
    let mut cache = StreamPageCache::default();
    for index in 0..2 {
        cache.append(index, byte_page(32 * 1024 * 1024 - overhead)).unwrap();
    }
    let snapshot = cache.snapshot(StreamTerminal::Loading, None);
    assert_eq!(snapshot.pages.len(), 2);
    assert_eq!(
        snapshot
            .pages
            .iter()
            .map(|page| page.estimated_row_bytes())
            .sum::<usize>(),
        64 * 1024 * 1024
    );
    drop(snapshot);
    cache.append(2, byte_page(1)).unwrap();
    assert_eq!(cache.first_page(), 1);
    assert_eq!(cache.pages().len(), 2);
}

#[test]
fn rejected_pages_release_payloads_without_advancing_the_retained_window() {
    let mut cache = StreamPageCache::default();
    cache.append(0, page(&["id"], &[1])).unwrap();
    let mut malformed = page(&["id"], &[2]).as_ref().clone();
    malformed.rows[0].push(Value::Int(3));
    for (index, result, expected) in [
        (2, page(&["id"], &[2]), PageAppendError::OutOfOrder),
        (1, page(&["changed"], &[2]), PageAppendError::SchemaChanged),
        (1, Arc::new(malformed), PageAppendError::InvalidRowWidth),
    ] {
        let weak = Arc::downgrade(&result);
        assert_eq!(cache.append(index, result), Err(expected));
        assert!(weak.upgrade().is_none());
        assert_eq!(cache.total_rows(), 1);
        assert_eq!(cache.pages().len(), 1);
    }
    cache.append(1, page(&["id"], &[2])).unwrap();
    assert_eq!(cache.total_rows(), 2);
}

#[test]
fn repeated_empty_pages_do_not_accumulate_or_replace_retained_rows() {
    let mut cache = StreamPageCache::default();
    cache.append(0, page(&["id"], &[1])).unwrap();
    for index in 1..=1_000 {
        let result = page(&["id"], &[]);
        let weak = Arc::downgrade(&result);
        cache.append(index, result).unwrap();
        assert!(weak.upgrade().is_none());
        assert_eq!(cache.pages().len(), 1);
    }
    cache.append(1_001, page(&["id"], &[2])).unwrap();
    let snapshot = cache.snapshot(StreamTerminal::Complete, None);
    assert_eq!(snapshot.total_rows, 2);
    assert_eq!(snapshot.total_pages, 2);
    assert_eq!(snapshot.page_indices, vec![0, 1_001]);
}

#[test]
fn terminal_snapshots_keep_only_the_retained_window_and_release_on_drop() {
    let mut cache = StreamPageCache::default();
    let mut refs = Vec::new();
    for index in 0..12 {
        let result = page(&["id"], &[index]);
        refs.push(Arc::downgrade(&result));
        cache.append(index as u64, result).unwrap();
    }
    let snapshots: Vec<_> = [
        StreamTerminal::Complete,
        StreamTerminal::Cancelled,
        StreamTerminal::TimedOut,
        StreamTerminal::Failed("fixture failure".into()),
    ]
    .into_iter()
    .map(|terminal| cache.snapshot(terminal, None))
    .collect();
    for snapshot in &snapshots {
        assert_eq!(snapshot.page_indices, vec![8, 9, 10, 11]);
        assert_eq!(snapshot.total_rows, 12);
    }
    drop(cache);
    assert!(refs[..8].iter().all(|result| result.upgrade().is_none()));
    assert!(refs[8..].iter().all(|result| result.upgrade().is_some()));
    drop(snapshots);
    assert!(refs.iter().all(|result| result.upgrade().is_none()));
}
