use crate::capabilities::DataModel;

/// The family an engine is listed under when the user picks one, as the
/// macOS app groups them. It is not the data model: Cassandra reads and
/// writes rows of a table, but it is a wide-column store.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum EngineCategory {
    Relational,
    Document,
    KeyValue,
    Analytical,
    WideColumn,
}

impl EngineCategory {
    /// The family of an engine that names none of its own.
    pub fn of(model: DataModel) -> Self {
        match model {
            DataModel::Relational => Self::Relational,
            DataModel::KeyValue => Self::KeyValue,
            DataModel::Document => Self::Document,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_engine_without_a_family_of_its_own_takes_its_data_model_s() {
        assert_eq!(EngineCategory::of(DataModel::Relational), EngineCategory::Relational);
        assert_eq!(EngineCategory::of(DataModel::KeyValue), EngineCategory::KeyValue);
        assert_eq!(EngineCategory::of(DataModel::Document), EngineCategory::Document);
    }

    #[test]
    fn families_sort_in_the_order_the_chooser_lists_them() {
        let mut families = [
            EngineCategory::WideColumn,
            EngineCategory::Analytical,
            EngineCategory::KeyValue,
            EngineCategory::Document,
            EngineCategory::Relational,
        ];
        families.sort();

        assert_eq!(
            families,
            [
                EngineCategory::Relational,
                EngineCategory::Document,
                EngineCategory::KeyValue,
                EngineCategory::Analytical,
                EngineCategory::WideColumn,
            ]
        );
    }
}
