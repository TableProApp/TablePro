use std::hint::black_box;
use std::time::Instant;
use tablepro_app_services::completion::SchemaIndex;

fn main() {
    for count in [1_000, 10_000, 50_000] {
        let mut index = SchemaIndex::default();
        index.set_tables((0..count).map(|i| format!("tenant_{:03}.table_{i:05}", i / 500)).collect());
        let mut samples = Vec::new();
        for _ in 0..5 {
            let start = Instant::now();
            assert!(!black_box(&index).needs_columns(black_box("missing")));
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        println!("{count} tables: {samples:?} ms");
    }
}
