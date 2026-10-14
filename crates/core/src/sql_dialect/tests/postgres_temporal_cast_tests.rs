use super::*;

#[test]
fn temporal_columns_with_a_precision_still_get_their_cast() {
    for (reported, cast) in [
        ("timestamp(3) with time zone", "pg_catalog.timestamptz"),
        ("timestamp(6) without time zone", "pg_catalog.timestamp"),
        ("timestamp(0)", "pg_catalog.timestamp"),
        ("time(2) with time zone", "pg_catalog.timetz"),
        ("TIME(3)", "pg_catalog.time"),
        ("date", "pg_catalog.date"),
    ] {
        assert_eq!(postgres_temporal_cast_type(reported), Some(cast), "{reported}");
    }
    assert_eq!(postgres_temporal_cast_type("interval(3)"), None);
}
