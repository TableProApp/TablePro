use crate::byte_limit::ByteLimit;
use crate::error::DriverError;

// A file's catalog can repeat one long name across thousands of keys, so what a read holds grows with both; this
// bounds it the way `retained_bytes` measures a result's text.
#[derive(Debug)]
pub struct CatalogBudget {
    limit: u64,
    held: u64,
}

impl CatalogBudget {
    pub fn new(limit: ByteLimit) -> Self {
        Self {
            limit: limit.get(),
            held: 0,
        }
    }

    pub fn charge(&mut self, bytes: usize) -> Result<(), DriverError> {
        self.held = self.held.saturating_add(u64::try_from(bytes).unwrap_or(u64::MAX));
        match self.held > self.limit {
            true => Err(DriverError::CatalogTooLarge {
                limit_bytes: self.limit,
            }),
            false => Ok(()),
        }
    }

    // For work the engine does and lets go of within the read, such as a statement it compiles: it has to fit beside
    // what the read holds, and holds nothing after.
    pub fn fits(&self, bytes: usize) -> Result<(), DriverError> {
        match self.held.saturating_add(u64::try_from(bytes).unwrap_or(u64::MAX)) > self.limit {
            true => Err(DriverError::CatalogTooLarge {
                limit_bytes: self.limit,
            }),
            false => Ok(()),
        }
    }

    pub fn charge_text(&mut self, text: &str) -> Result<(), DriverError> {
        self.charge(text_bytes(text))
    }

    pub fn keep(&mut self, text: String) -> Result<String, DriverError> {
        self.charge_text(&text)?;
        Ok(text)
    }

    pub fn keep_optional(&mut self, text: Option<String>) -> Result<Option<String>, DriverError> {
        text.map(|text| self.keep(text)).transpose()
    }

    pub fn charge_texts<'a>(&mut self, texts: impl IntoIterator<Item = &'a String>) -> Result<(), DriverError> {
        texts.into_iter().try_for_each(|text| self.charge_text(text))
    }

    // For a text the read drops before it reads the next one, such as each child's CREATE TABLE.
    pub fn release_text(&mut self, text: &str) {
        self.held = self
            .held
            .saturating_sub(u64::try_from(text_bytes(text)).unwrap_or(u64::MAX));
    }
}

impl Default for CatalogBudget {
    fn default() -> Self {
        Self::new(ByteLimit::CATALOG_DEFAULT)
    }
}

fn text_bytes(text: &str) -> usize {
    size_of::<String>().saturating_add(text.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SLOT: usize = size_of::<String>();

    fn budget(bytes: u64) -> CatalogBudget {
        CatalogBudget::new(ByteLimit::new(bytes).unwrap())
    }

    #[test]
    fn a_text_costs_its_slot_and_its_length() {
        let mut budget = budget((SLOT + 5) as u64);

        assert_eq!(budget.keep("héll".to_owned()).as_deref(), Ok("héll"));
        assert_eq!(
            budget.charge_text("x"),
            Err(DriverError::CatalogTooLarge {
                limit_bytes: (SLOT + 5) as u64
            })
        );
    }

    #[test]
    fn the_limit_itself_still_fits() {
        let mut budget = budget(100);

        assert_eq!(budget.charge(100), Ok(()));
        assert!(budget.charge(1).is_err());
    }

    #[test]
    fn a_released_text_makes_room_again() {
        let mut budget = budget((SLOT * 2 + 8) as u64);
        let text = "a".repeat(8);

        budget.charge_text(&text).unwrap();
        budget.release_text(&text);
        budget.charge_text(&text).unwrap();
        assert_eq!(budget.keep_optional(Some(String::new())), Ok(Some(String::new())));
        assert!(budget.charge_texts([&"b".to_owned()]).is_err());
    }

    #[test]
    fn work_that_fits_beside_what_is_held_holds_nothing_after() {
        let mut budget = budget(100);
        budget.charge(60).unwrap();

        assert_eq!(budget.fits(40), Ok(()));
        assert!(budget.fits(41).is_err());
        assert_eq!(budget.charge(40), Ok(()), "fits charged nothing");
    }

    #[test]
    fn the_default_is_the_catalog_limit() {
        let mut budget = CatalogBudget::default();

        assert_eq!(budget.charge(64_000_000), Ok(()));
        assert_eq!(
            budget.charge(1),
            Err(DriverError::CatalogTooLarge {
                limit_bytes: 64_000_000
            })
        );
    }
}
