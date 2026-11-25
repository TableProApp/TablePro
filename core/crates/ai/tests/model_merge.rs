//! The merge rules in `model-merge-cases.json`, which the macOS app's
//! tests read too.

use serde::Deserialize;
use tablepro_ai::{Api, LiveModel, MergeRules, ModelInfo, ProviderCatalog, merge_models};

const CASES: &str = include_str!("model-merge-cases.json");

#[derive(Deserialize)]
struct Cases {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    api: String,
    hides_unknown: bool,
    live_ordered: bool,
    catalog: Option<ProviderCatalog>,
    live: Option<Vec<LiveModel>>,
    expected: Vec<Expected>,
}

#[derive(Deserialize)]
struct Expected {
    id: String,
    name: Option<String>,
    default: bool,
    deprecated: bool,
    offline: bool,
}

#[test]
fn every_shared_merge_case_holds() {
    let cases: Cases = serde_json::from_str(CASES).expect("the merge cases read");
    assert!(!cases.cases.is_empty());

    for case in cases.cases {
        let rules = MergeRules {
            api: Api::from_name(&case.api).expect("a known api"),
            hides_unknown: case.hides_unknown,
            live_ordered: case.live_ordered,
        };

        let merged = merge_models(case.catalog.as_ref(), rules, case.live.as_deref());

        let expected: Vec<ModelInfo> = case
            .expected
            .into_iter()
            .map(|model| ModelInfo {
                id: model.id,
                name: model.name,
                deprecated: model.deprecated,
                default: model.default,
                offline: model.offline,
            })
            .collect();
        assert_eq!(merged, expected, "{}", case.name);
    }
}
