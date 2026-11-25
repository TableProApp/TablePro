use std::sync::Arc;

use super::fuzzy;

// What a list ranks. The proposal itself is each app's, so it only names its label and its order among equal matches.
pub trait Ranked {
    fn label(&self) -> &str;

    // Lower comes first among equally close matches: what the statement already names before what it might.
    fn kind_rank(&self) -> u8;
}

// The closest match first, then by kind, ties in the catalog's order, which lists a table's columns as it defines them.
#[derive(Debug)]
pub struct Ranking<C> {
    candidates: Arc<[C]>,
    needle: String,
    ranked: Vec<u32>,
}

impl<C: Ranked> Ranking<C> {
    // `needle` is casefolded. With nothing typed every candidate matches equally: the matcher would rank by length
    // alone and put every short keyword above the columns.
    pub fn new(candidates: Arc<[C]>, needle: &str) -> Self {
        let mut scored: Vec<(u32, u8, u32)> = candidates
            .iter()
            .enumerate()
            .filter_map(|(at, candidate)| {
                let score = if needle.is_empty() {
                    0
                } else {
                    fuzzy::fuzzy_match(candidate.label(), needle)?
                };
                Some((score, candidate.kind_rank(), u32::try_from(at).ok()?))
            })
            .collect();
        scored.sort_unstable();
        Self {
            ranked: scored.into_iter().map(|(_, _, at)| at).collect(),
            candidates,
            needle: needle.to_owned(),
        }
    }
}

impl<C> Ranking<C> {
    pub fn candidates(&self) -> &Arc<[C]> {
        &self.candidates
    }

    pub fn needle(&self) -> &str {
        &self.needle
    }

    // Indexes into the candidates the word matches, closest first.
    pub fn ranked(&self) -> &[u32] {
        &self.ranked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Named(&'static str, u8);

    impl Ranked for Named {
        fn label(&self) -> &str {
            self.0
        }

        fn kind_rank(&self) -> u8 {
            self.1
        }
    }

    const COLUMN: u8 = 0;
    const TABLE: u8 = 1;
    const KEYWORD: u8 = 5;

    #[test]
    fn closer_matches_rank_first_then_by_kind_then_in_catalog_order() {
        let candidates: Arc<[Named]> = vec![
            Named("USING", KEYWORD),
            Named("product_status", TABLE),
            Named("users", TABLE),
            Named("user_id", COLUMN),
            Named("status", COLUMN),
        ]
        .into();

        let order = |needle: &str| Ranking::new(candidates.clone(), &fuzzy::casefold(needle)).ranked;

        assert_eq!(order("us"), [2, 3, 0, 4, 1]);
        assert_eq!(
            order(""),
            [3, 4, 1, 2, 0],
            "nothing typed ranks by kind, then catalog order"
        );
        assert_eq!(order("zz"), Vec::<u32>::new());
    }
}
