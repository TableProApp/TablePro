use std::collections::HashSet;

use serde::Deserialize;

use crate::catalog::{Api, CatalogModel, ProviderCatalog};

/// One model as a provider's own list gives it. A field it leaves out
/// comes from the catalog.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct LiveModel {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    /// `YYYY-MM-DD`.
    #[serde(default)]
    pub released: Option<String>,
    #[serde(default)]
    pub deprecated: bool,
    #[serde(default)]
    pub default: bool,
}

impl LiveModel {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelInfo {
    pub id: String,
    /// `None` when neither the provider nor the catalog names it.
    pub name: Option<String>,
    pub deprecated: bool,
    pub default: bool,
    /// From the catalog only, because the provider's list was not read.
    pub offline: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MergeRules {
    /// The protocol this client speaks to the provider.
    pub api: Api,
    /// Leave out a listed id the catalog does not know, for a vendor list
    /// that holds models no chat client can use.
    pub hides_unknown: bool,
    /// Keep the provider's order, for a list whose order is documented.
    pub live_ordered: bool,
}

/// The models to offer: the provider's list, its gaps filled from the
/// catalog, or the catalog's alone, each offline, when `live` is `None`.
pub fn merge_models(
    catalog: Option<&ProviderCatalog>,
    rules: MergeRules,
    live: Option<&[LiveModel]>,
) -> Vec<ModelInfo> {
    let Some(live) = live else {
        return offline(catalog, rules);
    };
    let mut seen = HashSet::new();
    let mut merged = Vec::new();
    for model in live {
        if !seen.insert(model.id.as_str()) {
            continue;
        }
        let entry = catalog.and_then(|catalog| catalog_entry(catalog, &model.id));
        match entry {
            Some(entry) if !entry.apis.contains(&rules.api) => continue,
            None if rules.hides_unknown => continue,
            _ => {}
        }
        merged.push(Merged {
            info: ModelInfo {
                id: model.id.clone(),
                name: present(model.name.as_deref())
                    .or_else(|| entry.and_then(|entry| present(entry.name.as_deref())))
                    .map(str::to_owned),
                deprecated: model.deprecated || entry.is_some_and(|entry| entry.deprecated),
                default: model.default,
                offline: false,
            },
            released: present(model.released.as_deref())
                .or_else(|| entry.and_then(|entry| present(entry.released.as_deref())))
                .map(str::to_owned),
        });
    }
    if !merged.iter().any(|model| model.info.default) {
        mark_default(&mut merged, catalog);
    }
    finish(merged, !rules.live_ordered)
}

fn offline(catalog: Option<&ProviderCatalog>, rules: MergeRules) -> Vec<ModelInfo> {
    let Some(catalog) = catalog else {
        return Vec::new();
    };
    let mut merged: Vec<Merged> = catalog
        .models
        .iter()
        .filter(|model| model.apis.contains(&rules.api))
        .map(|model| Merged {
            info: ModelInfo {
                id: model.id.clone(),
                name: present(model.name.as_deref()).map(str::to_owned),
                deprecated: model.deprecated,
                default: false,
                offline: true,
            },
            released: present(model.released.as_deref()).map(str::to_owned),
        })
        .collect();
    mark_default(&mut merged, Some(catalog));
    finish(merged, true)
}

struct Merged {
    info: ModelInfo,
    released: Option<String>,
}

fn mark_default(merged: &mut [Merged], catalog: Option<&ProviderCatalog>) {
    let Some(default) = catalog.and_then(|catalog| catalog.default.as_deref()) else {
        return;
    };
    if let Some(model) = merged.iter_mut().find(|model| model.info.id == default) {
        model.info.default = true;
    }
}

/// Newest first when `by_release`, those without a date after those with
/// one; then the default first and deprecated models last.
fn finish(mut merged: Vec<Merged>, by_release: bool) -> Vec<ModelInfo> {
    if by_release {
        merged.sort_by(|a, b| match (&a.released, &b.released) {
            (Some(a_day), Some(b_day)) => b_day.cmp(a_day).then_with(|| a.info.id.cmp(&b.info.id)),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => a.info.id.cmp(&b.info.id),
        });
    }
    merged.sort_by_key(|model| (model.info.deprecated, !model.info.default));
    merged.into_iter().map(|model| model.info).collect()
}

fn present(text: Option<&str>) -> Option<&str> {
    text.filter(|text| !text.trim().is_empty())
}

/// The catalog's entry for a listed id: the id itself, else the base of
/// a fine-tune (`ft:<base>:...`), else either without a trailing
/// `-YYYY-MM-DD` snapshot date.
pub(crate) fn catalog_entry<'a>(catalog: &'a ProviderCatalog, id: &str) -> Option<&'a CatalogModel> {
    if let Some(entry) = catalog.model(id) {
        return Some(entry);
    }
    let base = id
        .strip_prefix("ft:")
        .and_then(|rest| rest.split(':').next())
        .unwrap_or(id);
    if base != id
        && let Some(entry) = catalog.model(base)
    {
        return Some(entry);
    }
    without_snapshot_date(base).and_then(|undated| catalog.model(undated))
}

fn without_snapshot_date(id: &str) -> Option<&str> {
    let (base, date) = id.split_at_checked(id.len().checked_sub(11)?)?;
    let bytes = date.as_bytes();
    let shaped = bytes.len() == 11
        && bytes[0] == b'-'
        && bytes[5] == b'-'
        && bytes[8] == b'-'
        && [1, 2, 3, 4, 6, 7, 9, 10].iter().all(|&at| bytes[at].is_ascii_digit());
    (shaped && !base.is_empty()).then_some(base)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> ProviderCatalog {
        serde_json::from_str(
            r#"{"default":"gpt-5.5","models":[
                {"id":"gpt-5.5","name":"GPT-5.5","released":"2026-04-23","apis":["responses","chat-completions"]},
                {"id":"gpt-5.5-2026-04-23","name":"GPT-5.5 snapshot","apis":["responses"]}
            ]}"#,
        )
        .unwrap()
    }

    #[test]
    fn a_snapshot_and_a_fine_tune_find_their_base() {
        let catalog = catalog();

        assert_eq!(
            catalog_entry(&catalog, "ft:gpt-5.5:org::abc").map(|entry| entry.id.as_str()),
            Some("gpt-5.5")
        );
        assert_eq!(
            catalog_entry(&catalog, "gpt-5.5-2026-04-24").map(|entry| entry.id.as_str()),
            Some("gpt-5.5")
        );
        assert_eq!(
            catalog_entry(&catalog, "gpt-5.5-2026-04-23").map(|entry| entry.id.as_str()),
            Some("gpt-5.5-2026-04-23"),
            "an id the catalog lists is its own entry"
        );
        assert!(catalog_entry(&catalog, "gpt-5.5-mini").is_none());
    }

    #[test]
    fn only_a_whole_date_is_a_snapshot() {
        assert_eq!(without_snapshot_date("gpt-4o-2024-08-06"), Some("gpt-4o"));
        assert_eq!(without_snapshot_date("gpt-4o-2024-8-6"), None);
        assert_eq!(without_snapshot_date("-2024-08-06"), None);
        assert_eq!(without_snapshot_date("é-2024-08-06"), Some("é"));
        assert_eq!(without_snapshot_date("short"), None);
    }
}
