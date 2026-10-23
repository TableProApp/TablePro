use std::hint::black_box;
use std::time::Instant;
use tablepro_app_services::completion::SchemaIndex;

fn rss_kib() -> u64 {
    std::fs::read_to_string("/proc/self/status").unwrap().lines()
        .find(|line| line.starts_with("VmRSS:")).unwrap()
        .split_whitespace().nth(1).unwrap().parse().unwrap()
}

fn main() {
    let count: usize = std::env::args().nth(1).unwrap().parse().unwrap();
    let mut index = SchemaIndex::default();
    let tables: Vec<String> = (0..count).map(|i| format!("tenant_{:03}.table_{i:05}", i / 500)).collect();
    let before = rss_kib();
    let start = Instant::now();
    index.set_tables(black_box(tables));
    let millis = start.elapsed().as_secs_f64() * 1000.0;
    let after = rss_kib();
    assert!(index.needs_columns(&format!("tenant_{:03}.table_{:05}", (count-1)/500, count-1)));
    assert!(!index.needs_columns("missing"));
    println!("{count} tables: construction={millis:.3} ms; before={before} KiB; after={after} KiB; delta={} KiB", after.saturating_sub(before));
}
