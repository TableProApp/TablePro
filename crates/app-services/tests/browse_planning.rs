#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_app_services::browse_query::{BrowseTarget, PageQuery};
use tablepro_core::FilterSet;

#[test]
fn unfiltered_native_browsing_needs_no_gui_or_sql_execution() {
    let filter = FilterSet::default();
    for driver_id in ["mongodb", "redis"] {
        let target = BrowseTarget {
            driver_id,
            schema: None,
            table: "items",
            columns: &[],
            filter: &filter,
            hidden_columns: None,
        };
        assert!(matches!(target.page(0, 100, None, None).unwrap(), PageQuery::Native));
    }
}
